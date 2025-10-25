from rest_framework import serializers
from .models import GMXPosition, ProtocolState

class GMXPositionSerializer(serializers.ModelSerializer):
    class Meta:
        model = GMXPosition
        fields = ['position_id', 'is_closed', 'created_at', 'updated_at']

class HeartbeatSerializer(serializers.Serializer):
    heartbeat_seconds = serializers.IntegerField(min_value=300)

    def update(self, instance, validated_data):
        instance.heartbeat_seconds = validated_data.get('heartbeat_seconds', instance.heartbeat_seconds)
        instance.save()
        return instance
    
class UpdateBasketWeightSerializer(serializers.Serializer):
    basketIndex = serializers.IntegerField(min_value=0)
    newWeightBps = serializers.IntegerField(min_value=0, max_value=10000) # Basis points (0-10000)

class SuccessStatusSerializer(serializers.Serializer):
    """A generic serializer for a simple success status message."""
    status = serializers.CharField()

class UpdateWeightsSuccessSerializer(serializers.Serializer):
    """Serializer for the successful response of the TriggerUpdateWeightsView."""
    status = serializers.CharField()
    transactionHash = serializers.CharField()
    basketIndex = serializers.IntegerField()
    newWeightBps = serializers.IntegerField()

class ErrorResponseSerializer(serializers.Serializer):
    """A generic serializer for error responses."""
    error = serializers.CharField()