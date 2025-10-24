import os
import sys
from pathlib import Path # <-- 1. Import Path
from celery import Celery

try:
    import dotenv
    dotenv_path = Path(__file__).resolve().parent.parent / '.env'
    if dotenv_path.exists():
        dotenv.load_dotenv(dotenv_path=dotenv_path)
except ImportError:
    pass
# ---

if 'worker' in sys.argv:
    os.environ['CELERY_IS_RUNNING'] = 'True'

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'config.settings')

app = Celery('config')

app.config_from_object('django.conf:settings', namespace='CELERY')

app.autodiscover_tasks()

@app.task(bind=True)
def debug_task(self):
    print(f'Request: {self.request!r}')