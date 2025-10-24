from celery import shared_task
import logging
from django.utils import timezone
from .services import PythPriceService, COMMODITY_PYTH_IDS
from .models import Commodity

log = logging.getLogger(__name__)

@shared_task(name="gmx.update_pyth_prices")
def update_pyth_prices_task():
    """
    Celery task to update all commodity prices from the Pyth Network.
    """
    log.info("Executing update_pyth_prices_task...")
    try:
        for item in COMMODITY_PYTH_IDS:
            Commodity.objects.get_or_create(symbol=item["Commodity"])

        service = PythPriceService()
        prices = service.get_all_commodity_prices()

        if not prices:
            log.warning("Pyth price update task finished, but no prices were returned.")
            return "No prices found to update."

        updated_count = 0
        commodities_to_update = []
        for symbol, price in prices.items():
            try:
                commodity = Commodity.objects.get(symbol=symbol)
                commodity.current_price = price
                commodity.last_price_update = timezone.now()
                commodities_to_update.append(commodity)
                log.info(f"Updated price for {symbol} to ${price:,.4f}")
                updated_count += 1
            except Commodity.DoesNotExist:
                log.warning(f"Commodity with symbol '{symbol}' not found in the database. Skipping update.")

        # For better performance, update all objects at once
        if commodities_to_update:
            Commodity.objects.bulk_update(commodities_to_update, ['current_price', 'last_price_update'])
        
        return f"Pyth price update completed successfully. {updated_count} commodities updated."
    
    except Exception as e:
        log.exception(f"An unexpected error occurred in the Pyth price update task: {e}")
        return f"Task failed with error: {e}"
