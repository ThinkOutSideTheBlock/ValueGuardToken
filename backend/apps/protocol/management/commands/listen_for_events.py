import asyncio
import structlog
import time
from decimal import Decimal

from django.core.management.base import BaseCommand
from django.conf import settings
from web3 import Web3
from web3.types import EventData, LogReceipt
from ...models import MintIntent, RedeemIntent, IntentStatus, BasketAllocationUpdate, EventListenerState
from ...services import OnChainService

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
        log.info("Handler: DepositProcessed event received.", args=args)
        if not args.success:
            log.error("DepositProcessed event reported failure.", args=args)
            return

        scaled_amount = Decimal(args.amount) / DECIMAL_SCALAR
        matching_intent = await MintIntent.objects.filter(
            user=args.user,
            deposit_amount=scaled_amount,
            status=IntentStatus.PENDING
        ).order_by('-created_at').afirst()

        if not matching_intent:
            log.warning("Received a DepositProcessed event but could not find a matching pending MintIntent.", args=args)
            return

        log.info("Found matching mint intent.", intent_id=matching_intent.intent_id)
        try:
            await self.onchain_service.execute_mint_intent(matching_intent.intent_id, args.depositId)
            matching_intent.status = IntentStatus.PROCESSED
            await matching_intent.asave()
            log.info("Successfully processed mint intent.", intent_id=matching_intent.intent_id)
        except Exception as e:
            log.error("Failed to execute mint intent on-chain.", intent_id=matching_intent.intent_id, error=str(e), exc_info=True)
            matching_intent.status = IntentStatus.FAILED
            await matching_intent.asave()

    async def handle_withdrawal_processed(self, event: EventData):
        args = event.args
        log.info("Handler: WithdrawalProcessed event received.", args=args)
        if not args.success:
            log.error("WithdrawalProcessed event reported failure.", args=args)
            return

        scaled_amount = Decimal(args.amount) / DECIMAL_SCALAR
        matching_intent = await RedeemIntent.objects.filter(
            user=args.user,
            shield_amount=scaled_amount,
            status=IntentStatus.PENDING
        ).order_by('-created_at').afirst()

        if not matching_intent:
            log.warning("Received a WithdrawalProcessed event but could not find a matching pending RedeemIntent.", args=args)
            return

        log.info("Found matching redeem intent.", intent_id=matching_intent.intent_id)
        try:
            await self.onchain_service.execute_redeem_intent(matching_intent.intent_id)
            matching_intent.status = IntentStatus.PROCESSED
            await matching_intent.asave()
            log.info("Successfully processed redeem intent.", intent_id=matching_intent.intent_id)
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
        log.info("Basket allocation update saved to database.", tx_hash=tx_hash)
        try:
            await self.onchain_service.rebalance_positions()
        except Exception as e:
            log.error("Failed to trigger rebalancePositions.", tx_hash=tx_hash, error=str(e), exc_info=True)

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
        w3 = Web3(Web3.AsyncHTTPProvider(settings.NODE_RPC_URL))
        w3_ws = Web3(Web3.AsyncWebsocketProvider(settings.NODE_WS_URL))

        self.onchain_service = OnChainService()
        contracts = {
            self.onchain_service.vault_contract: [
                ('MintIntentCreated', self.handle_mint_intent_created),
                ('RedeemIntentCreated', self.handle_redeem_intent_created)
            ],
            self.onchain_service.basket_manager_contract: [
                ('DepositProcessed', self.handle_deposit_processed),
                ('WithdrawalProcessed', self.handle_withdrawal_processed),
                ('BasketAllocationUpdated', self.handle_basket_allocation_updated)
            ]
        }
        for contract, events in contracts.items():
            self.contract_addresses.add(contract.address)
            for event_name, handler in events:
                event_abi = next((abi for abi in contract.abi if abi.get('name') == event_name and abi.get('type') == 'event'), None)
                if event_abi:
                    topic_hash = w3.keccak(text=f"{event_name}({','.join([w3.get_abi_input_types(abi_input) for abi_input in event_abi['inputs']])})").hex()
                    self.event_handlers[topic_hash] = {
                        'name': event_name,
                        'handler': handler,
                        'abi': contract.abi
                    }

        state, _ = await EventListenerState.objects.aget_or_create(pk=1, defaults={'last_processed_block': await w3.eth.block_number})
        start_block = state.last_processed_block + 1
        latest_block = await w3.eth.block_number
        
        if start_block <= latest_block:
            log.info("Catching up on missed blocks", from_block=start_block, to_block=latest_block)
            for block_num in range(start_block, latest_block + 1):
                await self.process_block(w3, block_num)

        log.info("Finished catch-up. Subscribing to new blocks...")
        
        subscription_id = await w3_ws.eth.subscribe('newHeads')
        
        async for block_header in w3_ws.eth.socket.listen_to_subscription(subscription_id):
            if block_header:
                block_number = block_header['number']
                await self.process_block(w3, block_number)

    def handle(self, *args, **options):
        while True:
            try:
                asyncio.run(self.main_loop())
            except Exception as e:
                log.error("Main listener loop crashed. Reconnecting...", error=str(e), exc_info=True)
                time.sleep(settings.EVENT_LISTENER_ERROR_POLL_INTERVAL_SECONDS)