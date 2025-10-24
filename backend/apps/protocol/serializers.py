from rest_framework import serializers
from .models import GMXPosition, ProtocolState

class GMXPositionSerializer(serializers.ModelSerializer):
    class Meta:
        model = GMXPosition
        fields = ['position_id', 'is_closed', 'created_at', 'updated_at']

class HeartbeatSerializer(serializers.Serializer):
    seconds = serializers.IntegerField(min_value=1)

    def update(self, instance, validated_data):
        instance.heartbeat_seconds = validated_data.get('seconds', instance.heartbeat_seconds)
        instance.save()
        return instance
    
class UpdateBasketWeightSerializer(serializers.Serializer):
    basketIndex = serializers.IntegerField(min_value=0)
    newWeightBps = serializers.IntegerField(min_value=0, max_value=10000) # Basis points (0-10000)