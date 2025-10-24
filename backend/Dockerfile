# Use a specific version for reproducibility
# --- IMPORTANT: Add syntax directive for BuildKit ---
# This line MUST be the very first line of the Dockerfile
# syntax=docker/dockerfile:1

FROM python:3.13-slim


# Set environment variables
ENV PYTHONDONTWRITEBYTECODE 1
ENV PYTHONUNBUFFERED 1

RUN apt-get update && apt-get install -y postgresql-client && rm -rf /var/lib/apt/lists/*

# Set work directory
WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install -r requirements.txt

# Copy the entrypoint script
COPY entrypoint.sh .
# Ensure the script is executable
RUN chmod +x ./entrypoint.sh

# Copy project code
COPY . .

# Mount the secret .env file to the root of the app.
# 'manage.py' will now automatically load it.
RUN --mount=type=secret,id=env_file,target=.env \
    python manage.py collectstatic --noinput

# Expose port
EXPOSE 8000

# --- UPDATED ---
# Set the entrypoint to our script
ENTRYPOINT ["./entrypoint.sh"]

# Use the "shell form" of CMD to allow environment variable substitution.
# The shell will now correctly process ${GUNICORN_TIMEOUT:-30}.
CMD gunicorn config.wsgi:application \
    --bind 0.0.0.0:8000 \
    --workers ${GUNICORN_WORKERS:-3} \
    --worker-class gevent \
    --timeout ${GUNICORN_TIMEOUT:-120}