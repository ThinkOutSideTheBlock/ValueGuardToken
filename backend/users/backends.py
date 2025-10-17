from django.contrib.auth.backends import ModelBackend
from .models import User

class WalletAuthBackend(ModelBackend):

    def authenticate(self, request, username=None, password=None, **kwargs):
        wallet_address = username or kwargs.get("wallet_address")
        if not wallet_address or not password:
            return None

        try:
            user = User.objects.get(wallet_address=wallet_address.lower())
        except User.DoesNotExist:
            return None

        if user.check_password(password) and self.user_can_authenticate(user):
            return user
        return None
