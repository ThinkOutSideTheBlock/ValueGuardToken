from celery import shared_task
import structlog
from .services import NAVCalculatorService

log = structlog.get_logger(__name__)

@shared_task(name="protocol.update_nav")
def update_nav_task():
    """
    Periodic Celery task to calculate and update the protocol's NAV.
    """
    log.info("Executing periodic NAV update task.")
    try:
        service = NAVCalculatorService()
        service.run()
    except Exception as e:
        log.error("Error during NAV update task.", error=str(e), exc_info=True)

# We will create a separate task for the event listener.