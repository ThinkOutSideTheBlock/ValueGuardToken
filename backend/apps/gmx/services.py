import requests
import structlog
from decimal import Decimal

log = structlog.get_logger(__name__)


COMMODITY_PYTH_IDS = [
    {"Commodity" :"Metal.XAU/USD" ,"PriceFeedID": "0x765d2ba906dbc32ca17cc11f5310a89e9ee1f6420508c63861f2f8ba4ee34bb2"},# Gold 
    {"Commodity" :"Metal.XAG/USD" ,"PriceFeedID": "0xf2fb02c32b055c805e7238d628e5e9dadef274376114eb1f012337cabe93871e"},# Silver
    {"Commodity" :"Commodities.USOILSPOT" ,"PriceFeedID": "0x925ca92ff005ae943c158e3563f59698ce7e75c5a8c8dd43303a0a154887b3e6"},# Oil
]

class PythPriceService:
    """Fetches commodity prices from the Pyth Network API."""
    BASE_URL = "https://hermes.pyth.network/api"

    def _get_price_id_for_symbol(self, symbol: str) -> str | None:
        for item in COMMODITY_PYTH_IDS:
            if item["Commodity"] == symbol:
                return item["PriceFeedID"]
        return None

    def get_price_by_symbol(self, symbol: str) -> Decimal | None:
        """Fetches the price for a single commodity symbol."""
        price_id = self._get_price_id_for_symbol(symbol)
        if not price_id:
            log.warning(f"[PythService] Price ID for symbol '{symbol}' not found.")
            return None

        url = f"{self.BASE_URL}/v2/updates/price/latest?ids[]={price_id}"
        try:
            response = requests.get(url, timeout=10)
            response.raise_for_status()
            data = response.json()
            
            parsed_data = data.get('parsed', [])
            if not parsed_data:
                raise ValueError("Parsed data is missing in Pyth response.")

            price_info = parsed_data[0]['price']
            price = Decimal(price_info['price']) * (Decimal(10) ** price_info['expo'])
            return price
        except (requests.RequestException, IndexError, KeyError, ValueError) as e:
            log.error(f"[PythService] Failed to get price for {symbol}: {e}")
            return None

    def get_all_commodity_prices(self) -> dict[str, Decimal]:
        """Fetches prices for all configured commodities in a single batch request."""
        price_ids = [item["PriceFeedID"] for item in COMMODITY_PYTH_IDS]
        if not price_ids:
            log.info("[PythService] No Pyth commodity IDs configured.")
            return {}

        params = [("ids[]", pid) for pid in price_ids]
        url = f"{self.BASE_URL}/v2/updates/price/latest"
        
        try:
            response = requests.get(url, params=params, timeout=15)
            response.raise_for_status()
            data = response.json()
            
            parsed_data = data.get('parsed', [])
            if not parsed_data:
                raise ValueError("Parsed data is missing in Pyth response.")

            # Create a mapping from price ID back to commodity symbol for easier processing
            id_to_symbol_map = {item["PriceFeedID"]: item["Commodity"] for item in COMMODITY_PYTH_IDS}
            
            results = {}
            for item in parsed_data:
                symbol = id_to_symbol_map.get(item['id'])
                if symbol:
                    price_info = item['price']
                    price = Decimal(price_info['price']) * (Decimal(10) ** price_info['expo'])
                    results[symbol] = price
            
            return results
        except (requests.RequestException, KeyError, ValueError) as e:
            log.error(f"[PythService] Failed to get all commodity prices: {e}")
            return {}
