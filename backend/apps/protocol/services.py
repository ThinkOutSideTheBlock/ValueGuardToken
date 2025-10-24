import structlog
from web3 import Web3
from web3.middleware import ExtraDataToPOAMiddleware
from eth_account import Account
from decimal import Decimal
from django.conf import settings

from .models import GMXPosition, NAVUpdateLog
from .utils import load_abi

log = structlog.get_logger(__name__)

# A constant for scaling to 18 decimal places for on-chain calls
WEI_SCALAR = 10**18

class OnChainService:
    """
    Handles all direct interactions with smart contracts.
    """
    def __init__(self):
        self.w3 = Web3(Web3.HTTPProvider(settings.NODE_RPC_URL))
        # Add PoA middleware if connecting to chains like Polygon, Goerli, etc.
        self.w3.middleware_onion.inject(ExtraDataToPOAMiddleware, layer=0)

        if not self.w3.is_connected():
            raise ConnectionError("Failed to connect to blockchain node.")

        # --- Hot Wallet Setup ---
        if not settings.HOT_WALLET_PRIVATE_KEY:
            raise ValueError("HOT_WALLET_PRIVATE_KEY is not set.")
        self.account = Account.from_key(settings.HOT_WALLET_PRIVATE_KEY)
        self.hot_wallet_address = self.account.address
        log.info("OnChainService initialized", hot_wallet=self.hot_wallet_address)

        # --- Load Contracts ---
        self.vault_contract = self.w3.eth.contract(address=settings.VAULT_CONTRACT_ADDRESS, abi=load_abi("Vault"))
        self.basket_manager_contract = self.w3.eth.contract(address=settings.BASKET_MANAGER_CONTRACT_ADDRESS, abi=load_abi("BasketManager"))
        self.gmx_reader_contract = self.w3.eth.contract(address=settings.GMX_READER_CONTRACT_ADDRESS, abi=load_abi("GMXReader"))

    def _send_transaction(self, built_tx: dict) -> str:
        """Signs and sends a transaction, then waits for the receipt."""
        nonce = self.w3.eth.get_transaction_count(self.hot_wallet_address)
        tx_with_nonce = {**built_tx, 'nonce': nonce}
        
        # TODO: For production, consider a more robust gas estimation strategy
        tx_with_nonce['gas'] = self.w3.eth.estimate_gas(tx_with_nonce)
        
        signed_tx = self.account.sign_transaction(tx_with_nonce)
        tx_hash = self.w3.eth.send_raw_transaction(signed_tx.rawTransaction)
        
        log.info("Transaction sent, waiting for receipt...", tx_hash=tx_hash.hex())
        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash)
        
        if receipt.status != 1:
            log.error("Transaction failed!", tx_hash=tx_hash.hex(), receipt=receipt)
            raise Exception(f"Transaction failed: {tx_hash.hex()}")
            
        log.info("Transaction confirmed.", tx_hash=tx_hash.hex())
        return tx_hash.hex()

    def get_positions_size(self, position_ids: list[str]) -> Decimal:
        """Calls the GMX reader contract to get the total size of given positions."""
        # TODO: Replace 'getMarketValue' with the correct function name from your GMXReader ABI.
        # This is a placeholder for the logic.
        function_name = "getMarketValue" # <-- CHANGE THIS
        log.info("Calling GMX Reader to get position sizes.", function=function_name, position_count=len(position_ids))

        total_size_wei = 0
        # Scenario 1: The function accepts a list of IDs
        try:
            # total_size_wei = self.gmx_reader_contract.functions[function_name](position_ids).call()
            pass # Comment this out and uncomment the line above when ready
        except Exception as e:
            # Scenario 2: The function must be called for each ID individually
            log.warning("Calling GMX Reader with a list failed, trying one-by-one.", error=str(e))
            # for pos_id in position_ids:
            #     total_size_wei += self.gmx_reader_contract.functions[function_name](pos_id).call()

        # Using a dummy value until the function is known
        if total_size_wei == 0:
            log.warning("Using dummy value for position size.")
            total_size_wei = 1_000_000 * WEI_SCALAR

        return Decimal(total_size_wei) / Decimal(WEI_SCALAR)

    def update_basket_nav(self, total_position_size: Decimal) -> str:
        """Calls the Basket Manager contract to update the on-chain NAV."""
        log.info("Building transaction to update basket NAV.", new_nav=total_position_size)
        # TODO: Replace 'updateNAV' with the correct function name from your BasketManager ABI.
        function_name = "updateNAV" # <-- CHANGE THIS
        nav_in_wei = int(total_position_size * WEI_SCALAR)
        
        tx = self.basket_manager_contract.functions[function_name](nav_in_wei).build_transaction({
            'from': self.hot_wallet_address,
        })
        return self._send_transaction(tx)

    def execute_mint_intent(self, intent_id: str, deposit_id: int) -> str:
        """Calls the Vault contract to execute a mint intent."""
        log.info("Building transaction to execute mint intent.", intent_id=intent_id)
        # Convert hex string to bytes32 for the contract call
        intent_id_bytes = bytes.fromhex(intent_id[2:])
        
        tx = self.vault_contract.functions.executeMintIntent(intent_id_bytes, deposit_id).build_transaction({
            'from': self.hot_wallet_address,
        })
        return self._send_transaction(tx)

    def execute_redeem_intent(self, intent_id: str) -> str:
        """Calls the Vault contract to execute a redeem intent."""
        log.info("Building transaction to execute redeem intent.", intent_id=intent_id)
        intent_id_bytes = bytes.fromhex(intent_id[2:])
        
        tx = self.vault_contract.functions.executeRedeemIntent(intent_id_bytes).build_transaction({
            'from': self.hot_wallet_address,
        })
        return self._send_transaction(tx)

    def update_basket_weight(self, basket_index: int, new_weight_bps: int) -> str:
        """Calls the Basket Manager contract to update a basket weight."""
        log.info("Building transaction to update basket weight.", basket_index=basket_index, new_weight_bps=new_weight_bps)
        tx = self.basket_manager_contract.functions.updateBasketWeight(basket_index, new_weight_bps).build_transaction({
            'from': self.hot_wallet_address,
        })
        return self._send_transaction(tx)

    def rebalance_positions(self) -> str:
        """Calls the Basket Manager contract to trigger a rebalance."""
        log.info("Building transaction to rebalance positions.")
        tx = self.basket_manager_contract.functions.rebalancePositions().build_transaction({
            'from': self.hot_wallet_address,
        })
        return self._send_transaction(tx)


class NAVCalculatorService:
    """Service to calculate the total position size (NAV) periodically."""
    def __init__(self):
        self.onchain_service = OnChainService()

    def run(self):
        """Executes the NAV calculation and update process."""
        log.info("Running NAV Calculator Service...")
        
        open_positions = GMXPosition.objects.filter(is_closed=False)
        if not open_positions.exists():
            log.warning("No open GMX positions found in DB. Skipping NAV update.")
            return

        position_ids = [p.position_id for p in open_positions]
        
        total_size = self.onchain_service.get_positions_size(position_ids)
        log.info("Calculated total position size.", total_size=total_size)

        tx_hash = None
        try:
            tx_hash = self.onchain_service.update_basket_nav(total_size)
        except Exception as e:
            log.error("Failed to update on-chain NAV.", error=str(e), exc_info=True)
        
        # Log the update regardless of on-chain success
        NAVUpdateLog.objects.create(
            total_position_size=total_size,
            onchain_tx_hash=tx_hash
        )
        
        log.info("NAV Calculator Service finished.")