#!/bin/sh

# Exit immediately if a command exits with a non-zero status.
set -e

# The "$@" variable holds all the arguments passed to the script.
# For example, if the CMD is ["python", "manage.py", "runserver"],
# then "$@" will be "python manage.py runserver".
# The 'exec' command replaces the shell process with the command,
# which is a best practice for running processes in Docker.
exec "$@"