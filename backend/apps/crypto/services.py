
import os
import logging
from decimal import Decimal
from django.core.exceptions import ImproperlyConfigured
from web3 import Web3

log = logging.getLogger(__name__)

CHAINLINK_ADDRESSES = {
    "ETHEREUM" : {
        "NODE_RPC_URL_ENV_NAME":"NODE_RPC_URL_ETHEREUM",
        "ABI" : [
            {"inputs":[],"name":"decimals","outputs":[{"internalType":"uint8","name":"","type":"uint8"}],"stateMutability":"view","type":"function"},
            {"inputs":[],"name":"latestRoundData","outputs":[{"internalType":"uint80","name":"roundId","type":"uint80"},{"internalType":"int256","name":"answer","type":"int256"},{"internalType":"uint256","name":"startedAt","type":"uint256"},{"internalType":"uint256","name":"updatedAt","type":"uint256"},{"internalType":"uint80","name":"answeredInRound","type":"uint80"}],"stateMutability":"view","type":"function"}
        ],
        "pairs" :[
            {            
                "pair": "ETH/USD",
                "address": "0x5f4ec3df9cbd43714fe2740f5e3616155c5b8419"
            }
        ]        
    }
}

class ChainlinkPriceService:
    """Fetches crypto prices from Chainlink contracts directly on-chain."""

    def __init__(self, network="ETHEREUM"):
        network_config = CHAINLINK_ADDRESSES.get(network)
        if not network_config:
            raise ImproperlyConfigured(f"Configuration for network '{network}' not found.")

        rpc_env_var = network_config.get("NODE_RPC_URL_ENV_NAME")
        if not rpc_env_var:
            raise ImproperlyConfigured(f"NODE_RPC_URL_ENV_NAME not defined for network '{network}'.")

        rpc_url = os.getenv(rpc_env_var)
        if not rpc_url:
            raise ImproperlyConfigured(f"Environment variable '{rpc_env_var}' is not set.")

        self.w3 = Web3(Web3.HTTP_Provider(rpc_url))
        if not self.w3.is_connected():
            raise ConnectionError(f"Failed to connect to the blockchain node at {rpc_env_var}.")
        
        self.network = network
        self.abi = network_config["ABI"]
        self.price_feeds = {
            item['symbol']: item 
            for item in network_config.get("pairs", [])
        }

    def get_price(self, crypto_symbol: str) -> Decimal | None:
        """Fetches price data for a specific crypto from its Chainlink contract."""
        feed_info = self.price_feeds.get(crypto_symbol)
        if not feed_info:
            log.warning(f"[ChainlinkService] Chainlink address for '{crypto_symbol}' on network '{self.network}' not found.")
            return None

        try:
            contract = self.w3.eth.contract(address=feed_info['address'], abi=self.abi)
            decimals = contract.functions.decimals().call()
            latest_data = contract.functions.latestRoundData().call()
            # latest_data is a tuple: (roundId, answer, startedAt, updatedAt, answeredInRound)
            price = Decimal(latest_data[1]) / (Decimal(10) ** decimals)
            return price
        except Exception as e:
            log.error(f"[ChainlinkService] Failed to get price for {crypto_symbol}: {e}")
            return None

    def get_all_prices(self) -> dict[str, Decimal]:
        """Fetches prices for all configured crypto pairs for the network."""
        results = {}
        for symbol in self.price_feeds.keys():
            price = self.get_price(symbol)
            if price is not None:
                results[symbol] = price
        return results