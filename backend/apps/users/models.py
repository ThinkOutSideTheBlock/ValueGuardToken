from django.db import models
from django.contrib.auth.models import AbstractBaseUser, PermissionsMixin, BaseUserManager
import uuid
from django.utils import timezone

class UserManager(BaseUserManager):
    use_in_migrations = True

    def _create_user(self, wallet_address, is_staff, is_superuser, **extra_fields):
        if not wallet_address:
            raise ValueError("Wallet address must be set")
        wallet_address = wallet_address.lower()
        user = self.model(wallet_address=wallet_address, is_staff=is_staff,
                          is_superuser=is_superuser, **extra_fields)
        user.set_unusable_password()
        user.save(using=self._db)
        send_welcome_email.delay(user.wallet_address)
        return user

    def create_user(self, wallet_address, **extra_fields):
        return self._create_user(wallet_address, is_staff=False, is_superuser=False, **extra_fields)

    def create_superuser(self, wallet_address, password=None, **extra_fields):
        user = self._create_user(wallet_address, is_staff=True, is_superuser=True, **extra_fields)
        if password:
            user.set_password(password)
            user.save()
        return user


class User(AbstractBaseUser, PermissionsMixin):
    ROLE_USER = "user"
    ROLE_ADMIN = "admin"

    ROLE_CHOICES = [
        (ROLE_USER, "User"),
        (ROLE_ADMIN, "Admin"),
    ]

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    wallet_address = models.CharField(max_length=42, unique=True)
    display_name = models.CharField(max_length=150, blank=True)
    role = models.CharField(max_length=20, choices=ROLE_CHOICES, default=ROLE_USER)

    is_active = models.BooleanField(default=True)
    is_staff = models.BooleanField(default=False)
    date_joined = models.DateTimeField(default=timezone.now)

    login_nonce = models.CharField(max_length=128, blank=True, null=True)
    nonce_created_at = models.DateTimeField(blank=True, null=True)

    objects = UserManager()

    USERNAME_FIELD = "wallet_address"
    REQUIRED_FIELDS = []

    def save(self, *args, **kwargs):
        if self.wallet_address:
            self.wallet_address = self.wallet_address.lower()
        if not self.display_name and self.wallet_address:
            wa = self.wallet_address
            self.display_name = f"{wa[:6]}...{wa[-4:]}"
        super().save(*args, **kwargs)

    def __str__(self):
        return f"{self.wallet_address} ({self.role})"
