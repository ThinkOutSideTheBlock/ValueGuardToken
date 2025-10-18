import os
from pathlib import Path
from django.core.wsgi import get_wsgi_application

try:
    import dotenv
    dotenv_path = Path(__file__).resolve().parent.parent / '.env'
    if dotenv_path.exists():
        dotenv.load_dotenv(dotenv_path=dotenv_path)
except ImportError:
    pass

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'config.settings')
application = get_wsgi_application()