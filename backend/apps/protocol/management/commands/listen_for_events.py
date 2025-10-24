import asyncio
import structlog
import time
from decimal import Decimal

from django.core.management.base import BaseCommand
from django.conf import settings
from web3 import Web3, AsyncWeb3
from web3.types import EventData, LogReceipt
from ...models import (
    MintIntent, RedeemIntent, IntentStatus, BasketAllocationUpdate,
    EventListenerState, DepositProcessedEvent, WithdrawalProcessedEvent,
    RebalanceExecutedEvent
)
from ...services import AsyncOnChainService, OnChainService
from ...tasks import update_nav_task, trigger_rebalance_task

log = structlog.get_logger(__name__)
DECIMAL_SCALAR = Decimal(10) ** 18

class Command(BaseCommand):
    help = 'Starts the robust, asynchronous blockchain event listener using WebSockets.'

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.onchain_service = None
        self.event_handlers = {}
        self.contract_addresses = set()

    # --- Event Handlers ---

    async def handle_mint_intent_created(self, event: EventData):
        args = event.args
        intent_id_hex = args.intentId.hex()
        log.info("Handler: New MintIntentCreated event received.", intent_id=intent_id_hex)
        await MintIntent.objects.aupdate_or_create(
            intent_id=intent_id_hex,
            defaults={
                'user': args.user,
                'deposit_asset': args.depositAsset,
                'deposit_amount': Decimal(args.depositAmount) / DECIMAL_SCALAR,
                'locked_nav': Decimal(args.lockedNAV) / DECIMAL_SCALAR,
                'expected_shield': Decimal(args.expectedShield) / DECIMAL_SCALAR,
                'execution_fee': Decimal(args.executionFee) / DECIMAL_SCALAR,
                'expires_at': args.expiresAt,
                'status': IntentStatus.PENDING,
            }
        )
        log.info("Mint intent saved to database.", intent_id=intent_id_hex)

    async def handle_redeem_intent_created(self, event: EventData):
        args = event.args
        intent_id_hex = args.intentId.hex()
        log.info("Handler: New RedeemIntentCreated event received.", intent_id=intent_id_hex)
        await RedeemIntent.objects.aupdate_or_create(
            intent_id=intent_id_hex,
            defaults={
                'user': args.user,
                'output_asset': args.outputAsset,
                'shield_amount': Decimal(args.shieldAmount) / DECIMAL_SCALAR,
                'locked_nav': Decimal(args.lockedNAV) / DECIMAL_SCALAR,
                'expected_stablecoin': Decimal(args.expectedStablecoin) / DECIMAL_SCALAR,
                'execution_fee': Decimal(args.executionFee) / DECIMAL_SCALAR,
                'expires_at': args.expiresAt,
                'status': IntentStatus.PENDING,
            }
        )
        log.info("Redeem intent saved to database.", intent_id=intent_id_hex)

    async def handle_deposit_processed(self, event: EventData):
        args = event.args
        tx_hash = event.transactionHash.hex()
        log.info("Handler: DepositProcessed event received.", args=args)
        
        # Save the event for audit trail
        await DepositProcessedEvent.objects.acreate(
            transaction_hash=tx_hash,
            deposit_id=args.depositId,
            user=args.user,
            amount=Decimal(args.amount) / DECIMAL_SCALAR,
            success=args.success
        )

        if not args.success:
            log.warning("DepositProcessed event reported failure.", args=args)
            return

        # Find the original intentId by calling the contract
        intent_id_hex = await self.onchain_service.get_intent_id_from_deposit(args.depositId)
        if not intent_id_hex:
            log.warning("Could not find associated intentId for deposit.", deposit_id=args.depositId)
            return

        matching_intent = await MintIntent.objects.filter(intent_id=intent_id_hex, status=IntentStatus.PENDING).afirst()
        if not matching_intent:
            log.warning("Found intentId but no matching PENDING intent in DB.", intent_id=intent_id_hex, deposit_id=args.depositId)
            return

        log.info("Found matching mint intent, proceeding to execute.", intent_id=matching_intent.intent_id)
        try:
            await self.onchain_service.execute_mint_intent(matching_intent.intent_id)
            matching_intent.status = IntentStatus.PROCESSED
            await matching_intent.asave()
            log.info("Successfully executed mint intent.", intent_id=matching_intent.intent_id)
            
            # Trigger immediate NAV update
            update_nav_task.delay(trigger_source=f"mint_completed_{matching_intent.intent_id[:10]}")
        except Exception as e:
            log.error("Failed to execute mint intent on-chain.", intent_id=matching_intent.intent_id, error=str(e), exc_info=True)
            matching_intent.status = IntentStatus.FAILED
            await matching_intent.asave()

    async def handle_withdrawal_processed(self, event: EventData):
        args = event.args
        tx_hash = event.transactionHash.hex()
        log.info("Handler: WithdrawalProcessed event received.", args=args)

        # Save the event for audit trail
        await WithdrawalProcessedEvent.objects.acreate(
            transaction_hash=tx_hash,
            withdrawal_id=args.withdrawalId,
            user=args.user,
            amount=Decimal(args.amount) / DECIMAL_SCALAR,
            success=args.success
        )

        if not args.success:
            log.warning("WithdrawalProcessed event reported failure.", args=args)
            return

        # Find the original intentId by calling the contract
        intent_id_hex = await self.onchain_service.get_intent_id_from_withdrawal(args.withdrawalId)
        if not intent_id_hex:
            log.warning("Could not find associated intentId for withdrawal.", withdrawal_id=args.withdrawalId)
            return

        matching_intent = await RedeemIntent.objects.filter(intent_id=intent_id_hex, status=IntentStatus.PENDING).afirst()
        if not matching_intent:
            log.warning("Found intentId but no matching PENDING intent in DB.", intent_id=intent_id_hex, withdrawal_id=args.withdrawalId)
            return
            
        log.info("Found matching redeem intent, proceeding to execute.", intent_id=matching_intent.intent_id)
        try:
            await self.onchain_service.execute_redeem_intent(matching_intent.intent_id)
            matching_intent.status = IntentStatus.PROCESSED
            await matching_intent.asave()
            log.info("Successfully executed redeem intent.", intent_id=matching_intent.intent_id)
            
            # Trigger immediate NAV update
            update_nav_task.delay(trigger_source=f"redeem_completed_{matching_intent.intent_id[:10]}")
        except Exception as e:
            log.error("Failed to execute redeem intent on-chain.", intent_id=matching_intent.intent_id, error=str(e), exc_info=True)
            matching_intent.status = IntentStatus.FAILED
            await matching_intent.asave()

    async def handle_basket_allocation_updated(self, event: EventData):
        args = event.args
        tx_hash = event.transactionHash.hex()
        log.info("Handler: BasketAllocationUpdated event received.", args=args, tx_hash=tx_hash)

        await BasketAllocationUpdate.objects.aupdate_or_create(
            transaction_hash=tx_hash,
            defaults={
                'basket_index': args.basketIndex,
                'old_weight_bps': args.oldWeightBps,
                'new_weight_bps': args.newWeightBps,
            }
        )
        log.info("Basket allocation update saved to database. Triggering rebalance task with cooldown.", tx_hash=tx_hash)
        
        # Trigger the delayed rebalance task
        trigger_rebalance_task.apply_async()

    async def handle_rebalance_executed(self, event: EventData):
        args = event.args
        tx_hash = event.transactionHash.hex()
        log.info("Handler: RebalanceExecuted event received.", args=args, tx_hash=tx_hash)

        await RebalanceExecutedEvent.objects.acreate(
            transaction_hash=tx_hash,
            from_token=args.fromToken,
            to_token=args.toToken,
            amount=Decimal(args.amount) / DECIMAL_SCALAR,
            timestamp=args.timestamp
        )
        log.info("Rebalance execution saved to database. Triggering immediate NAV update.", tx_hash=tx_hash)

        # Trigger immediate NAV update as positions have changed
        update_nav_task.delay(trigger_source=f"rebalance_executed_{tx_hash[:10]}")


    # --- Core Processing Logic ---
    # ... (process_log and process_block methods remain the same as the previous async version)
    async def process_log(self, w3: Web3, log_entry: LogReceipt):
        """Decodes a single log and calls the appropriate handler."""
        topic = log_entry['topics'][0].hex()
        if topic in self.event_handlers:
            contract_abi = self.event_handlers[topic]['abi']
            event_name = self.event_handlers[topic]['name']
            
            # The event must be retrieved from the contract object to be decoded
            contract_obj = w3.eth.contract(abi=contract_abi)
            event_obj = getattr(contract_obj.events, event_name)
            
            try:
                decoded_event = event_obj().process_log(log_entry)
                handler_func = self.event_handlers[topic]['handler']
                await handler_func(decoded_event)
            except Exception as e:
                log.error("Failed to decode or handle event", log=log_entry, error=e, exc_info=True)

    async def process_block(self, w3: Web3, block_number: int):
        """Fetches a block and processes all relevant logs within it."""
        log.info("Processing block", block_number=block_number)
        try:
            block = await w3.eth.get_block(block_number, full_transactions=True)
            for tx in block['transactions']:
                receipt = await w3.eth.get_transaction_receipt(tx['hash'])
                for log_entry in receipt['logs']:
                    if log_entry['address'] in self.contract_addresses:
                        await self.process_log(w3, log_entry)
            
            await EventListenerState.objects.aupdate_or_create(
                pk=1, defaults={'last_processed_block': block_number}
            )
        except Exception as e:
            log.error("Failed to process block", block_number=block_number, error=e, exc_info=True)

    # --- Main Asynchronous Loop ---
    async def main_loop(self):
        w3_http = AsyncWeb3(AsyncWeb3.AsyncHTTPProvider(settings.NODE_RPC_URL))
        self.onchain_service = AsyncOnChainService(w3=w3_http)
        
        contracts = {
            self.onchain_service.vault_manager_contract: [
                ('MintIntentCreated', self.handle_mint_intent_created),
                ('RedeemIntentCreated', self.handle_redeem_intent_created)
            ],
            self.onchain_service.basket_manager_contract: [
                ('DepositProcessed', self.handle_deposit_processed),
                ('WithdrawalProcessed', self.handle_withdrawal_processed),
                ('BasketAllocationUpdated', self.handle_basket_allocation_updated),
                ('RebalanceExecuted', self.handle_rebalance_executed)
            ]
        }
        self.contract_addresses.clear()
        self.event_handlers.clear()
        for contract, events in contracts.items():
            self.contract_addresses.add(contract.address)
            for event_name, handler in events:
                event_abi = next((abi for abi in contract.abi if abi.get('name') == event_name and abi.get('type') == 'event'), None)
                if event_abi:
                    input_types = [inp['type'] for inp in event_abi['inputs']]
                    topic_hash = w3_http.keccak(text=f"{event_name}({','.join(input_types)})").hex()
                    self.event_handlers[topic_hash] = {
                        'name': event_name,
                        'handler': handler,
                        'abi': contract.abi
                    }

        latest_block = await w3_http.eth.block_number
        state, _ = await EventListenerState.objects.aget_or_create(pk=1, defaults={'last_processed_block': await w3_http.eth.block_number})
        last_processed_block = state.last_processed_block

        while True:
            try:
                latest_block = await w3_http.eth.block_number
                
                # If new blocks have been mined since the last check
                if latest_block > last_processed_block:
                    log.info("New blocks detected.", from_block=last_processed_block + 1, to_block=latest_block)
                    
                    # Process all blocks from the last processed one up to the latest
                    for block_num in range(last_processed_block + 1, latest_block + 1):
                        await self.process_block(w3_http, block_num)
                    
                    last_processed_block = latest_block

                # Wait for a short interval before checking again
                await asyncio.sleep(settings.EVENT_LISTENER_POLL_INTERVAL_SECONDS)

            except Exception as e:
                log.error("Error in polling loop. Retrying...", error=str(e), exc_info=True)
                await asyncio.sleep(settings.EVENT_LISTENER_ERROR_POLL_INTERVAL_SECONDS)

    def handle(self, *args, **options):
        # The outer while True loop for reconnection is no longer strictly necessary
        # as the inner loop handles errors, but we keep it for robustness.
        while True:
            try:
                asyncio.run(self.main_loop())
            except Exception as e:
                log.error("Main listener loop crashed fatally. Reconnecting...", error=str(e), exc_info=True)
                time.sleep(settings.EVENT_LISTENER_ERROR_POLL_INTERVAL_SECONDS)