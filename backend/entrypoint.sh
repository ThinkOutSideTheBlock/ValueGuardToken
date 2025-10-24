#!/bin/sh

set -e

echo "🚀 Starting entrypoint..."

# --- Wait for PostgreSQL to be ready ---
echo "⏳ Waiting for PostgreSQL to start..."
until pg_isready -h "${POSTGRES_HOST}" -p "5432" -U "${POSTGRES_USER}"; do
  sleep 2
done
echo "✅ PostgreSQL is ready!"

# --- Apply Django migrations ---
echo "📦 Running Django migrations..."
python manage.py makemigrations users --noinput
python manage.py makemigrations protocol --noinput
python manage.py migrate --noinput

# --- Collect static files ---
echo "🧹 Collecting static files..."
python manage.py collectstatic --noinput

# --- Create superuser (wallet_address-based) ---
if [ "$DJANGO_SUPERUSER_WALLET" ] && [ "$DJANGO_SUPERUSER_PASSWORD" ]; then
  echo "👑 Creating superuser if not exists..."
  python manage.py shell << END
from django.contrib.auth import get_user_model
User = get_user_model()
wallet = "${DJANGO_SUPERUSER_WALLET}".lower()
if not User.objects.filter(wallet_address=wallet).exists():
    User.objects.create_superuser(
        wallet_address=wallet,
        password="${DJANGO_SUPERUSER_PASSWORD}"
    )
    print("✅ Superuser created successfully.")
else:
    print("ℹ️ Superuser already exists.")
END
fi

# --- Execute the container’s main command (Gunicorn / Celery) ---
echo "🚀 Starting main process..."
exec "$@"
