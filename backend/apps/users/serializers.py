from rest_framework import serializers
from .models import User
from rest_framework_simplejwt.serializers import TokenRefreshSerializer

class UserSerializer(serializers.ModelSerializer):
    class Meta:
        model = User
        fields = ("id", "wallet_address", "display_name", "role", "date_joined")

# --- INPUT SERIALIZERS ---

class RequestNonceSerializer(serializers.Serializer):
    wallet_address = serializers.CharField(max_length=42, help_text="The wallet address of the user.")

class VerifySignatureSerializer(serializers.Serializer):
    wallet_address = serializers.CharField(max_length=42, help_text="The wallet address of the user.")
    signature = serializers.CharField(help_text="The signature of the message provided by the nonce endpoint.")


# --- OUTPUT (RESPONSE) SERIALIZERS ---

class NonceResponseSerializer(serializers.Serializer):
    """
    Serializer for the response of the RequestNonceView.
    """
    message = serializers.CharField(help_text="The message that the user needs to sign.")
    nonce = serializers.CharField(help_text="The unique nonce for this login attempt.")

class VerifySignatureResponseSerializer(serializers.Serializer):
    """
    Serializer for a successful response from the VerifySignatureView.
    """
    access = serializers.CharField(help_text="JWT access token for authentication.")
    refresh = serializers.CharField(help_text="JWT refresh token to get a new access token.")
    user = UserSerializer(help_text="Information about the authenticated user.")

class AccessTokenResponseSerializer(serializers.Serializer):
    """
    Serializer for the response of the token refresh endpoint.
    """
    access = serializers.CharField(help_text="A new JWT access token.")