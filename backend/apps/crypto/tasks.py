
from celery import shared_task
import logging
from django.utils import timezone
from .services import ChainlinkPriceService
from .models import CryptoCurrency

log = logging.getLogger(__name__)

@shared_task(name="crypto.update_chainlink_prices")
def update_chainlink_prices_task(network="ETHEREUM"):
    """
    Celery task to update all crypto prices from Chainlink for a given network.
    """
    log.info(f"Executing update_chainlink_prices_task for network: {network}...")
    try:
        service = ChainlinkPriceService(network=network)
        prices = service.get_all_prices()

        if not prices:
            log.warning("Chainlink price update task finished, but no prices were returned.")
            return "No prices found to update."
        
        crypto_to_update = []
        for symbol, price in prices.items():
            try:
                crypto = CryptoCurrency.objects.get(symbol=symbol)
                crypto.current_price = price
                crypto.last_price_update = timezone.now()
                crypto_to_update.append(crypto)
                log.info(f"Updated price for {symbol} to ${price:,.4f}")
            except CryptoCurrency.DoesNotExist:
                log.warning(f"CryptoCurrency with symbol '{symbol}' not found in DB. Skipping.")
        
        if crypto_to_update:
            CryptoCurrency.objects.bulk_update(crypto_to_update, ['current_price', 'last_price_update'])
            
        return f"Chainlink update for {network} completed. {len(crypto_to_update)} prices updated."
    
    except Exception as e:
        log.exception(f"An unexpected error occurred in the Chainlink price update task: {e}")
        return f"Task failed with error: {e}"