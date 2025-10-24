import time
import structlog
from web3 import AsyncWeb3, Web3
from web3.middleware import ExtraDataToPOAMiddleware
from eth_account import Account
from eth_account.messages import encode_defunct
from decimal import Decimal, getcontext
from django.conf import settings

from .models import GMXPosition, NAVUpdateLog
from .utils import load_abi

log = structlog.get_logger(__name__)

# Set precision for Decimal calculations
getcontext().prec = 50

# Decimal Constants for conversion
GMX_DECIMALS = 30
USDC_DECIMALS = 6
TARGET_DECIMALS = 18
GMX_SCALAR = Decimal(10) ** (GMX_DECIMALS - TARGET_DECIMALS)
USDC_SCALAR = Decimal(10) ** (TARGET_DECIMALS - USDC_DECIMALS)
WEI_SCALAR = Decimal(10) ** TARGET_DECIMALS

class OnChainService:
    """
    Handles all direct interactions with smart contracts.
    """
    def __init__(self, w3: Web3 | AsyncWeb3):
        self.w3 = w3
        #self.w3.middleware_onion.inject(ExtraDataToPOAMiddleware, layer=0)
        # if not self.w3.is_connected():
        #     raise ConnectionError("Web3 provider passed to OnChainService is not connected.")

        self.account = Account.from_key(settings.HOT_WALLET_PRIVATE_KEY)
        self.hot_wallet_address = self.account.address
        log.info("OnChainService initialized", hot_wallet=self.hot_wallet_address)

        # --- Load Contracts ---
        self.vault_manager_contract = self.w3.eth.contract(address=settings.VAULT_MANAGER_CONTRACT_ADDRESS, abi=load_abi("VaultManager"))
        self.basket_manager_contract = self.w3.eth.contract(address=settings.BASKET_MANAGER_CONTRACT_ADDRESS, abi=load_abi("BasketManager"))
        self.basket_oracle_contract = self.w3.eth.contract(address=settings.BASKET_ORACLE_CONTRACT_ADDRESS, abi=load_abi("BasketOracle"))
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

    def get_intent_id_from_deposit(self, deposit_id: int) -> str | None:
        """Reads the associated intentId from a pending deposit."""
        try:
            deposit_data = self.basket_manager_contract.functions.pendingDeposits(deposit_id).call()
            # associatedOrders should contain the intentId
            associated_orders = deposit_data[3]
            if associated_orders:
                return associated_orders[0].hex() # Return the first associated order as hex
        except Exception as e:
            log.error("Failed to read pendingDeposits", deposit_id=deposit_id, error=e)
        return None

    def get_intent_id_from_withdrawal(self, withdrawal_id: int) -> str | None:
        """Reads the associated intentId from a pending withdrawal."""
        try:
            withdrawal_data = self.basket_manager_contract.functions.pendingWithdrawals(withdrawal_id).call()
            associated_orders = withdrawal_data[3]
            if associated_orders:
                return associated_orders[0].hex()
        except Exception as e:
            log.error("Failed to read pendingWithdrawals", withdrawal_id=withdrawal_id, error=e)
        return None

    def get_total_basket_weights(self) -> int:
        """Calls BasketManager to get the sum of all targetWeightBps."""
        try:
            return self.basket_manager_contract.functions.getTotalTargetWeights().call()
        except Exception as e:
            log.error("Failed to get total basket weights", error=e)
            return 0

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

    def execute_mint_intent(self, intent_id: str) -> str:
        log.info("Building transaction to execute mint intent.", intent_id=intent_id)
        intent_id_bytes = bytes.fromhex(intent_id[2:])
        tx = self.vault_manager_contract.functions.executeMintIntent(intent_id_bytes).build_transaction({'from': self.hot_wallet_address})
        return self._send_transaction(tx)

    def execute_redeem_intent(self, intent_id: str) -> str:
        log.info("Building transaction to execute redeem intent.", intent_id=intent_id)
        intent_id_bytes = bytes.fromhex(intent_id[2:])
        tx = self.basket_manager_contract.functions.executeRedeemIntent(intent_id_bytes).build_transaction({'from': self.hot_wallet_address})
        return self._send_transaction(tx)

    def update_basket_weight(self, basket_index: int, new_weight_bps: int) -> str:
        """Calls the Basket Manager contract to update a basket weight."""
        log.info("Building transaction to update basket weight.", basket_index=basket_index, new_weight_bps=new_weight_bps)
        tx = self.basket_manager_contract.functions.updateBasketWeight(basket_index, new_weight_bps).build_transaction({
            'from': self.hot_wallet_address,
        })
        return self._send_transaction(tx)

    def rebalance_positions(self) -> str:
        log.info("Building transaction to rebalance positions.")
        fee_in_wei = self.w3.to_wei(settings.REBALANCE_EXECUTION_FEE_ETH, 'ether')
        tx = self.basket_manager_contract.functions.rebalancePositions().build_transaction({
            'from': self.hot_wallet_address,
            'value': fee_in_wei
        })
        return self._send_transaction(tx)

    def submit_nav(self, nav_data: dict) -> str:
        """Signs NAV data and submits it to the BasketOracle."""
        log.info("Signing and submitting NAV data.", nav_data=nav_data)
        
        # Prepare data for hashing
        nav_per_token = nav_data['navPerToken']
        total_value = nav_data['totalManagedValue']
        shield_supply = nav_data['shieldSupply']
        timestamp = nav_data['timestamp']

        # EIP-712 style packing might be safer, but using keccak256 as specified
        message_hash = self.w3.solidity_keccak(
            ['uint256', 'uint256', 'uint256', 'uint256'],
            [nav_per_token, total_value, shield_supply, timestamp]
        )
        
        # Sign the hash (EIP-191)
        signed_message = self.account.sign_message(encode_defunct(hexstr=message_hash.hex()))
        signature = signed_message.signature

        tx = self.basket_oracle_contract.functions.submitNAV(
            nav_per_token,
            total_value,
            shield_supply,
            signature
        ).build_transaction({'from': self.hot_wallet_address})
        
        return self._send_transaction(tx)

class NAVCalculatorService:
    """Service to calculate the total position size (NAV) periodically."""
    def __init__(self):
        w3_http = Web3(Web3.HTTPProvider(settings.NODE_RPC_URL))
        self.onchain_service = OnChainService(w3=w3_http)

    def run(self, trigger_source="scheduled"):
        log.info("Running NAV Calculator Service.", trigger=trigger_source)
        
        # 1. Get position keys from BasketManager
        basket_length = self.onchain_service.basket_manager_contract.functions.getBasketLength().call()
        position_keys = []
        for i in range(basket_length):
            alloc = self.onchain_service.basket_manager_contract.functions.getBasketAllocation(i).call()
            pos_key_raw = alloc[5]
            if isinstance(pos_key_raw, bytes):
                pos_key_hex = pos_key_raw.hex()
                # Check if the key is not the zero bytes32 value
                if int(pos_key_hex, 16) != 0:
                    position_keys.append("0x" + pos_key_hex)

        # 2. Get real position values from GMX
        total_gmx_value = Decimal(0)
        for key_hex in position_keys:
            key_bytes = bytes.fromhex(key_hex[2:])
            pos_data = self.onchain_service.gmx_reader_contract.functions.getPosition(
                settings.GMX_DATA_STORE_ADDRESS, key_bytes
            ).call()
            # pos_data structure: (size_usd, collateral_usd, average_price, entry_funding_rate, ...)
            collateral_usd_gmx = pos_data[1]
            total_gmx_value += Decimal(collateral_usd_gmx) / GMX_SCALAR

        # 3. Get idle reserves from BasketManager
        stable_config = self.onchain_service.basket_manager_contract.functions.stablecoins(settings.USDC_ADDRESS).call()
        reserves_usdc = stable_config[3]
        idle_reserves_usd = Decimal(reserves_usdc) * USDC_SCALAR

        # 4. Get SHIELD supply
        shield_supply_wei = self.onchain_service.basket_manager_contract.functions.totalSupply().call()
        
        # 5. Calculate NAV
        total_managed_value = total_gmx_value + idle_reserves_usd
        if shield_supply_wei == 0:
            nav_per_token_wei = int(WEI_SCALAR) # Default $1.00
        else:
            nav_per_token_wei = int((total_managed_value * WEI_SCALAR * WEI_SCALAR) / Decimal(shield_supply_wei))

        nav_data = {
            'navPerToken': nav_per_token_wei,
            'totalManagedValue': int(total_managed_value * WEI_SCALAR),
            'shieldSupply': shield_supply_wei,
            'timestamp': int(time.time()),
        }

        # 6. Sign NAV data and submit on-chain
        tx_hash = None
        try:
            tx_hash = self.onchain_service.submit_nav(nav_data)
        except Exception as e:
            log.error("Failed to submit NAV on-chain.", error=str(e), exc_info=True)
        
        # Store log
        NAVUpdateLog.objects.create(total_position_size=total_managed_value, onchain_tx_hash=tx_hash)
        log.info("NAV Calculator Service finished.", nav_per_token=Decimal(nav_per_token_wei)/WEI_SCALAR)