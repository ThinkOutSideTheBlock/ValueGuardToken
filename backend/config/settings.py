import os
from pathlib import Path
from enum import Enum
from django.core.exceptions import ImproperlyConfigured
import dj_database_url
import structlog
from corsheaders.defaults import default_headers
from celery.schedules import crontab

# ==============================================================================
# CORE PATHS & SETTINGS
# ==============================================================================

BASE_DIR = Path(__file__).resolve().parent.parent
IS_MAIN_PROCESS = os.environ.get('RUN_MAIN') != 'true'

# ==============================================================================
# APPLICATION MODE CONFIGURATION
# ==============================================================================
class AppMode(str, Enum):
    """Available application modes."""
    DEVELOPMENT = "development"
    TESTING = "testing"
    PRODUCTION = "production"

APP_MODE: AppMode = AppMode(os.getenv("APP_MODE", AppMode.DEVELOPMENT))


# ==============================================================================
# SECURITY & DEBUGGING
# ==============================================================================
# SECRET_KEY: In production, this MUST be set in the environment.
SECRET_KEY = os.getenv("SECRET_KEY")
if APP_MODE == AppMode.PRODUCTION and not SECRET_KEY:
    raise ImproperlyConfigured("SECRET_KEY environment variable is required in production.")
elif not SECRET_KEY:
    SECRET_KEY = "django-insecure-development-fallback-key"

# DEBUG mode is only enabled in development.
DEBUG = APP_MODE == AppMode.DEVELOPMENT

_ALLOWED_HOSTS_RAW = os.getenv("ALLOWED_HOSTS", "")
if APP_MODE == AppMode.PRODUCTION:
    ALLOWED_HOSTS = [h.strip() for h in _ALLOWED_HOSTS_RAW.split(",") if h.strip()]
    if not ALLOWED_HOSTS:
        raise ImproperlyConfigured("ALLOWED_HOSTS must be set in production environment.")
else:
    ALLOWED_HOSTS = ["*"] # Allow all hosts in development for convenience


# ==============================================================================
# DJANGO CORE CONFIGURATION
# ==============================================================================
INSTALLED_APPS = [
    'django.contrib.admin',
    'django.contrib.auth',
    'django.contrib.contenttypes',
    'django.contrib.sessions',
    'django.contrib.messages',
    'django.contrib.staticfiles',
    'whitenoise.runserver_nostatic',

    # Third-party apps
    'rest_framework',
    'rest_framework_simplejwt',
    'drf_spectacular',
    'django_filters',
    'corsheaders',

    # Local apps
    'apps.core',
    'apps.users',
    'apps.gmx',
    'apps.crypto',
    'apps.protocol',
]

MIDDLEWARE = [
    'django.middleware.security.SecurityMiddleware',
    'whitenoise.middleware.WhiteNoiseMiddleware',
    'django.contrib.sessions.middleware.SessionMiddleware',
    'corsheaders.middleware.CorsMiddleware',
    'django.middleware.common.CommonMiddleware',
    'django.middleware.csrf.CsrfViewMiddleware',
    'django.contrib.auth.middleware.AuthenticationMiddleware',
    'apps.core.middleware.StructlogRequestMiddleware',
    'django.contrib.messages.middleware.MessageMiddleware',
    'django.middleware.clickjacking.XFrameOptionsMiddleware',
]

ROOT_URLCONF = 'config.urls'

TEMPLATES = [
    {
        'BACKEND': 'django.template.backends.django.DjangoTemplates',
        'DIRS': [],
        'APP_DIRS': True,
        'OPTIONS': {
            'context_processors': [
                'django.template.context_processors.debug',
                'django.template.context_processors.request',
                'django.contrib.auth.context_processors.auth',
                'django.contrib.messages.context_processors.messages',
            ],
        },
    },
]

WSGI_APPLICATION = 'config.wsgi.application'


# ==============================================================================
# DATABASE CONFIGURATION
# ==============================================================================
DATABASE_URL = os.getenv('DATABASE_URL')
CELERY_RUNNING = os.environ.get('CELERY_IS_RUNNING', 'False') == 'True'

if DATABASE_URL:
    DATABASES = {'default': dj_database_url.config(default=DATABASE_URL, conn_max_age=600)}
elif CELERY_RUNNING:
    raise ImproperlyConfigured(
        "Celery worker requires DATABASE_URL to be set for a server-based DB (e.g., PostgreSQL)."
    )
else:
    if APP_MODE == AppMode.DEVELOPMENT:
        sqlite_db_name = 'dev.sqlite3'
    elif APP_MODE == AppMode.TESTING:
        sqlite_db_name = 'test.sqlite3'
    else:
        raise ImproperlyConfigured("Production environment requires DATABASE_URL to be set.")
    DATABASES = {'default': {'ENGINE': 'django.db.backends.sqlite3', 'NAME': BASE_DIR / sqlite_db_name}}


# ==============================================================================
# PASSWORDS, INTERNATIONALIZATION, STATIC & MEDIA FILES
# ==============================================================================
AUTH_PASSWORD_VALIDATORS = [
    {'NAME': 'django.contrib.auth.password_validation.UserAttributeSimilarityValidator'},
    {'NAME': 'django.contrib.auth.password_validation.MinimumLengthValidator'},
    {'NAME': 'django.contrib.auth.password_validation.CommonPasswordValidator'},
    {'NAME': 'django.contrib.auth.password_validation.NumericPasswordValidator'},
]

LANGUAGE_CODE = 'en-us'
TIME_ZONE = 'UTC'
USE_I18N = True
USE_TZ = True

STATIC_URL = 'static/'
MEDIA_URL = '/media/'
MEDIA_ROOT = BASE_DIR / 'media'

STATIC_ROOT = BASE_DIR / 'staticfiles'
STATICFILES_STORAGE = 'whitenoise.storage.CompressedManifestStaticFilesStorage'

DEFAULT_AUTO_FIELD = 'django.db.models.BigAutoField'


# ==============================================================================
# THIRD-PARTY APPLICATION SETTINGS
# ==============================================================================
REST_FRAMEWORK = {
    'DEFAULT_AUTHENTICATION_CLASSES': ('rest_framework_simplejwt.authentication.JWTAuthentication',),
    'DEFAULT_SCHEMA_CLASS': 'drf_spectacular.openapi.AutoSchema',
    'DEFAULT_FILTER_BACKENDS': ['django_filters.rest_framework.DjangoFilterBackend'],
    'DEFAULT_PAGINATION_CLASS': 'rest_framework.pagination.PageNumberPagination',
    'PAGE_SIZE': 10,

    'DEFAULT_VERSIONING_CLASS': 'rest_framework.versioning.URLPathVersioning',
    'DEFAULT_VERSION': 'v1',  # The default version if none is specified in the URL
    'ALLOWED_VERSIONS': ['v1'], # A list of all supported versions
    'VERSION_PARAM': 'version', # The name of the URL keyword argument
}

SPECTACULAR_SETTINGS = {
    'TITLE': 'Value Guard Token API',
    'DESCRIPTION': 'API documentation for the Value Guard Token API service.',
    'VERSION': '1.0.0',
    'SERVE_INCLUDE_SCHEMA': False,
    'COMPONENT_SPLIT_REQUEST': True,
}


# ==============================================================================
# CUSTOM APPLICATION SETTINGS
# ==============================================================================
AUTH_USER_MODEL = 'users.User'
ADMIN_LOGIN_FORM = 'apps.users.forms.WalletAdminAuthenticationForm'

AUTHENTICATION_BACKENDS = [
    "apps.users.backends.WalletAuthBackend",
    'django.contrib.auth.backends.ModelBackend',
]

LOGIN_RATE_LIMIT_PER_MINUTE = int(os.getenv("LOGIN_RATE_LIMIT_PER_MINUTE", "5"))
LOGIN_RATE_LIMIT_PERIOD_SECONDS = int(os.getenv("LOGIN_RATE_LIMIT_PERIOD_SECONDS", "60"))

# --- CORS (Cross-Origin Resource Sharing) Configuration ---
CORS_ALLOWED_ORIGINS = []
_CORS_ALLOWED_ORIGINS_RAW = os.getenv("CORS_ALLOWED_ORIGINS_RAW", "")

if APP_MODE == AppMode.DEVELOPMENT and not _CORS_ALLOWED_ORIGINS_RAW:
    # If in development and no specific origins are set, default to common frontend ports.
    CORS_ALLOWED_ORIGINS = [
        "http://localhost:3000", "http://127.0.0.1:3000",
    ]
elif _CORS_ALLOWED_ORIGINS_RAW == "*":
    # --- THIS IS THE NEW LOGIC ---
    # If the env var is explicitly set to "*", allow any origin using a regex.
    # This is useful for flexible development environments but should be used
    # with caution in production.
    CORS_ALLOWED_ORIGIN_REGEXES = [
        r"^https?://.+$",
    ]
else:
    # In production or if specific origins are provided, use the exact list.
    CORS_ALLOWED_ORIGINS = [h.strip() for h in _CORS_ALLOWED_ORIGINS_RAW.split(",") if h.strip()]
    if APP_MODE == AppMode.PRODUCTION and not CORS_ALLOWED_ORIGINS:
        raise ImproperlyConfigured("CORS_ALLOWED_ORIGINS_RAW must be set in production and cannot be empty.")

# --- NEW: Allow credentials (cookies, auth headers) to be sent ---
# This is required for the "credentials mode: 'include'" error.
CORS_ALLOW_CREDENTIALS = True

# --- ADD THIS BLOCK TO ALLOW CUSTOM HEADERS ---
# We start with the library's default allowed headers and add our custom one.
# This ensures that standard headers like 'Authorization' continue to work.
CORS_ALLOW_HEADERS = list(default_headers) + [
    'x-platform',
]

# ==============================================================================
# LOGGING CONFIGURATION (Structured with structlog)
# ==============================================================================
LOG_DIR = BASE_DIR / "logs"
LOG_DIR.mkdir(exist_ok=True)
LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "formatters": {
        # Formatter for structlog JSON output
        "json_formatter": {
            "()": "structlog.stdlib.ProcessorFormatter",
            "processor": structlog.processors.JSONRenderer(),
        },
        # Formatter for console (for human readability in development)
        "console_formatter": {
            "()": "structlog.stdlib.ProcessorFormatter",
            "processor": structlog.dev.ConsoleRenderer(),
        },
    },
    "handlers": {
        "console": {
            "class": "logging.StreamHandler",
            "formatter": "console_formatter",
        },
        "file_info": {
            "class": "logging.handlers.RotatingFileHandler",
            "filename": LOG_DIR / "info.log",
            "maxBytes": 1024 * 1024 * 10,
            "backupCount": 5,
            "formatter": "json_formatter", # Use the JSON formatter
            "level": "INFO",
        },
        "file_error": {
            "class": "logging.handlers.RotatingFileHandler",
            "filename": LOG_DIR / "error.log",
            "maxBytes": 1024 * 1024 * 10,
            "backupCount": 5,
            "formatter": "json_formatter", # Use the JSON formatter
            "level": "ERROR",
        },
    },
    "loggers": {
        "django": {"handlers": ["console", "file_info"], "level": "INFO", "propagate": False},
        "django.request": {"handlers": ["file_error"], "level": "ERROR", "propagate": False},
        "apps": {"handlers": ["console", "file_info"], "level": "INFO", "propagate": False},
        "django.server": {"handlers": [], "level": "INFO", "propagate": False},
    },
}


structlog.configure(
    processors=[
        structlog.contextvars.merge_contextvars,
        structlog.stdlib.add_logger_name,
        structlog.stdlib.add_log_level,
        structlog.stdlib.PositionalArgumentsFormatter(),
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.StackInfoRenderer(),
        structlog.processors.format_exc_info,
        structlog.stdlib.ProcessorFormatter.wrap_for_formatter,
    ],
    logger_factory=structlog.stdlib.LoggerFactory(),
    wrapper_class=structlog.stdlib.BoundLogger,
    cache_logger_on_first_use=True,
)



# ==============================================================================
# EMAIL CONFIGURATION
# ==============================================================================
if APP_MODE == AppMode.DEVELOPMENT:
    EMAIL_BACKEND = 'django.core.mail.backends.console.EmailBackend'
else:
    EMAIL_BACKEND =  os.getenv('EMAIL_BACKEND') or 'django.core.mail.backends.smtp.EmailBackend'
    EMAIL_HOST = os.getenv('EMAIL_HOST')
    EMAIL_PORT = int(os.getenv('EMAIL_PORT', 587))
    EMAIL_USE_TLS = os.getenv('EMAIL_USE_TLS', 'True') == 'True'
    EMAIL_HOST_USER = os.getenv('EMAIL_HOST_USER')
    EMAIL_HOST_PASSWORD = os.getenv('EMAIL_HOST_PASSWORD')
    DEFAULT_FROM_EMAIL = os.getenv('DEFAULT_FROM_EMAIL', EMAIL_HOST_USER)
    if not all([EMAIL_HOST, EMAIL_HOST_USER, EMAIL_HOST_PASSWORD]):
        raise ImproperlyConfigured("Production requires EMAIL_HOST, EMAIL_HOST_USER, and EMAIL_HOST_PASSWORD.")


# ==============================================================================
# CELERY SETTINGS
# ==============================================================================
CELERY_BROKER_URL = os.getenv('CELERY_BROKER_URL', 'redis://localhost:6379/0')
CELERY_RESULT_BACKEND = os.getenv('CELERY_BROKER_URL', 'redis://localhost:6379/0')

if APP_MODE == AppMode.DEVELOPMENT and not os.getenv('CELERY_BROKER_URL'):
    CELERY_TASK_ALWAYS_EAGER = True
else:
    CELERY_TASK_ALWAYS_EAGER = False

CELERY_ACCEPT_CONTENT = ['json']
CELERY_TASK_SERIALIZER = 'json'
CELERY_RESULT_SERIALIZER = 'json'
CELERY_TIMEZONE = 'UTC'

# ==============================================================================
# SIMPLE JWT (JSON Web Token) CONFIGURATION
# ==============================================================================
from datetime import timedelta
access_token_lifetime_minutes = int(os.getenv("JWT_ACCESS_TOKEN_LIFETIME_MINUTES", 1440))  # 1 day
refresh_token_lifetime_days = int(os.getenv("JWT_REFRESH_TOKEN_LIFETIME_DAYS", 30))


SIMPLE_JWT = {
    'ACCESS_TOKEN_LIFETIME': timedelta(minutes=access_token_lifetime_minutes),
    'REFRESH_TOKEN_LIFETIME': timedelta(days=refresh_token_lifetime_days),
    
    'ROTATE_REFRESH_TOKENS': False,
    'BLACKLIST_AFTER_ROTATION': False,
    'UPDATE_LAST_LOGIN': False,

    'ALGORITHM': 'HS256',
    'SIGNING_KEY': SECRET_KEY,
    'VERIFYING_KEY': None,
    'AUDIENCE': None,
    'ISSUER': None,
    'JWK_URL': None,
    'LEEWAY': 0,

    'AUTH_HEADER_TYPES': ('Bearer',),
    'AUTH_HEADER_NAME': 'HTTP_AUTHORIZATION',
    'USER_ID_FIELD': 'id',
    'USER_ID_CLAIM': 'user_id',
    'USER_AUTHENTICATION_RULE': 'rest_framework_simplejwt.authentication.default_user_authentication_rule',

    'AUTH_TOKEN_CLASSES': ('rest_framework_simplejwt.tokens.AccessToken',),
    'TOKEN_TYPE_CLAIM': 'token_type',
    'TOKEN_USER_CLASS': 'rest_framework_simplejwt.models.TokenUser',

    'JTI_CLAIM': 'jti',
}

# ==============================================================================
# CACHING CONFIGURATION
# ==============================================================================
CACHE_URL = os.getenv('CACHE_URL')

if CACHE_URL:
    CACHES = {
        "default": {
            "BACKEND": "django_redis.cache.RedisCache",
            "LOCATION": CACHE_URL,
            "OPTIONS": {"CLIENT_CLASS": "django_redis.client.DefaultClient"},
        }
    }
elif APP_MODE == AppMode.DEVELOPMENT:
    cache_dir = BASE_DIR / "tmp" / "django_cache"
    cache_dir.mkdir(parents=True, exist_ok=True)
    CACHES = {
        'default': {
            'BACKEND': 'django.core.cache.backends.filebased.FileBasedCache',
            'LOCATION': str(cache_dir),
            'TIMEOUT': 300, # Default timeout for cache entries (in seconds)
        }
    }
else:
    # Production MUST have a CACHE_URL.
    raise ImproperlyConfigured("CACHE_URL environment variable is required in production.")

# ==============================================================================
# BLOCKCHAIN SETTINGS
# ==============================================================================

NODE_RPC_URL=os.getenv("NODE_RPC_URL")
NODE_WS_URL = os.getenv("NODE_WS_URL")

# --- Contract Addresses ---
VAULT_MANAGER_CONTRACT_ADDRESS = os.getenv("VAULT_MANAGER_CONTRACT_ADDRESS")
BASKET_MANAGER_CONTRACT_ADDRESS = os.getenv("BASKET_MANAGER_CONTRACT_ADDRESS")
BASKET_ORACLE_CONTRACT_ADDRESS = os.getenv("BASKET_ORACLE_CONTRACT_ADDRESS")

GMX_READER_CONTRACT_ADDRESS = os.getenv("GMX_READER_CONTRACT_ADDRESS")
GMX_DATA_STORE_ADDRESS = os.getenv("GMX_DATA_STORE_ADDRESS")
USDC_ADDRESS = os.getenv("USDC_ADDRESS")

# --- Task Intervals & Values ---
REBALANCE_COOLDOWN_SECONDS = int(os.getenv("REBALANCE_COOLDOWN_SECONDS", 300))
REBALANCE_EXECUTION_FEE_ETH = os.getenv("REBALANCE_EXECUTION_FEE_ETH", "0.1") 

# --- External Services ---
DATA_FETCHER_AI_AGENT_API_URL = os.getenv("DATA_FETCHER_AI_AGENT_API_URL")

NAV_UPDATE_INTERVAL_SECONDS = int(os.getenv("NAV_UPDATE_INTERVAL_SECONDS", 300))

HOT_WALLET_PRIVATE_KEY = os.getenv("HOT_WALLET_PRIVATE_KEY")

CELERY_BEAT_SCHEDULE = {
    'update-pyth-prices-every-minute': {
        'task': 'gmx.update_pyth_prices',
        'schedule': 60.0,
    },
    'update-chainlink-eth-prices-every-5-minutes': {
        'task': 'crypto.update_chainlink_prices', 
        'schedule': crontab(minute='*/5'),  
        'kwargs': {'network': 'ETHEREUM'}
    },
        'periodic-nav-update': {
        'task': 'protocol.update_nav',
        'schedule': NAV_UPDATE_INTERVAL_SECONDS,
    },
}

# ==============================================================================
# EVENT LISTENER SETTINGS
# ==============================================================================
EVENT_LISTENER_POLL_INTERVAL_SECONDS = int(os.getenv("EVENT_LISTENER_POLL_INTERVAL_SECONDS", 15))
EVENT_LISTENER_ERROR_POLL_INTERVAL_SECONDS = int(os.getenv("EVENT_LISTENER_ERROR_POLL_INTERVAL_SECONDS", 60))


# ==============================================================================
# STARTUP CONFIGURATION SUMMARY
# ==============================================================================
if IS_MAIN_PROCESS:
    db_config = DATABASES['default']
    db_engine = db_config['ENGINE'].split('.')[-1]
    if 'sqlite' in db_engine:
        db_info = f"SQLite ({db_config['NAME']})"
    else:
        db_info = f"{db_engine} ({db_config.get('HOST')}:{db_config.get('PORT')})"

    celery_mode = "Eager (Synchronous)" if CELERY_TASK_ALWAYS_EAGER else "Broker (Asynchronous)"

    cache_backend = CACHES['default']['BACKEND'].split('.')[-1]
    if 'RedisCache' in cache_backend:    
        cache_backend += f" ({CACHES['default']['LOCATION']})"
    elif 'FileBasedCache' in cache_backend:
        cache_backend += f" ({CACHES['default']['LOCATION']})"
    else:
        cache_backend += " (Unknown Location)"
    
    if CORS_ALLOWED_ORIGINS:
        _CORS_ALLOWED_ORIGINS = CORS_ALLOWED_ORIGINS
    elif CORS_ALLOWED_ORIGIN_REGEXES:
        _CORS_ALLOWED_ORIGINS = CORS_ALLOWED_ORIGIN_REGEXES
    else:
        _CORS_ALLOWED_ORIGINS = "None"
        

    print("-" * 60)
    print(f"[CONFIG] Application Mode:     {APP_MODE.value}")
    print(f"[CONFIG] Debug Mode:           {DEBUG}")
    print(f"[CONFIG] Database:             {db_info}")
    print(f"[CONFIG] Email Backend:        {EMAIL_BACKEND.split('.')[-2]}")
    print(f"[CONFIG] Celery Mode:          {celery_mode}")
    print(f"[CONFIG] Access Token Lifetime:{SIMPLE_JWT['ACCESS_TOKEN_LIFETIME']}")
    print(f"[CONFIG] Cache Backend:        {cache_backend}")
    print(f"[CONFIG] CORS_ALLOWED_ORIGINS:{_CORS_ALLOWED_ORIGINS}")
    print("-" * 60)

