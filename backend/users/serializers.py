from rest_framework import serializers
from .models import User

class UserSerializer(serializers.ModelSerializer):
    class Meta:
        model = User
        fields = ("id", "wallet_address", "display_name", "role", "date_joined")

class RequestNonceSerializer(serializers.Serializer):
    wallet_address = serializers.CharField(max_length=42)

class VerifySignatureSerializer(serializers.Serializer):
    wallet_address = serializers.CharField(max_length=42)
    signature = serializers.CharField()
