# apps/core/serializers.py
from rest_framework import serializers

class CacheKeySerializer(serializers.Serializer):
    """Serializer for the cache key in the request body."""
    key = serializers.CharField(
        help_text="The specific cache key to be deleted."
    )

class CacheStatusSerializer(serializers.Serializer):
    """Serializer for the status message in the response."""
    status = serializers.CharField(
        help_text="A message indicating the result of the cache operation."
    )

class ErrorDetailSerializer(serializers.Serializer):
    """A generic serializer for error responses."""
    error = serializers.CharField()