from rest_framework.permissions import BasePermission
from apps.users.models import User

class IsAdminRole(BasePermission):
    """
    Custom permission to only allow users with the 'admin' role.
    """

    def has_permission(self, request, view):
        # Check if the user is authenticated and has the 'admin' role.
        return bool(
            request.user and
            request.user.is_authenticated and
            request.user.role == User.ROLE_ADMIN
        )