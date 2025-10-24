import time
import uuid
import structlog
from django.utils.deprecation import MiddlewareMixin

log = structlog.get_logger(__name__)

class StructlogRequestMiddleware(MiddlewareMixin):
    def process_request(self, request):
        request_id = str(uuid.uuid4())

        user_id = "anonymous"
        if request.user and request.user.is_authenticated:
            user_id = request.user.id

        structlog.contextvars.bind_contextvars(
            request_id=request_id,
            http_method=request.method,
            http_path=request.path,
            remote_ip=request.META.get('REMOTE_ADDR'),
            user_id=user_id,
        )

        request.start_time = time.time()

    def process_response(self, request, response):
        duration = 0
        if hasattr(request, 'start_time'):
            duration = (time.time() - request.start_time) * 1000  # in milliseconds

        log.info(
            "request_finished",
            status_code=response.status_code,
            response_time_ms=f"{duration:.2f}",
        )
        
        structlog.contextvars.clear_contextvars()
        return response