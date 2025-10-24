import time
from celery import shared_task
import structlog
from .services import NAVCalculatorService
from django.conf import settings
from .services import OnChainService 

log = structlog.get_logger(__name__)

@shared_task(name="protocol.update_nav")
def update_nav_task(trigger_source="scheduled"):
    log.info("Executing NAV update task.", trigger=trigger_source)
    try:
        service = NAVCalculatorService()
        service.run(trigger_source=trigger_source)
    except Exception as e:
        log.error("Error during NAV update task.", error=str(e), exc_info=True)

@shared_task(name="protocol.trigger_rebalance")
def trigger_rebalance_task():
    """Waits for cooldown then triggers rebalancePositions."""
    log.info(f"Rebalance cooldown started. Waiting for {settings.REBALANCE_COOLDOWN_SECONDS} seconds.")
    time.sleep(settings.REBALANCE_COOLDOWN_SECONDS)
    
    log.info("Cooldown finished. Triggering rebalance.")
    try:
        service = OnChainService()
        service.rebalance_positions()
        # NAV update will be triggered by the RebalanceExecuted event
    except Exception as e:
        log.error("Error during rebalance trigger task.", error=str(e), exc_info=True)