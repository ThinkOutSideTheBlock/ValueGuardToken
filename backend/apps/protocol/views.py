import requests
import structlog
from django.conf import settings
from rest_framework import viewsets, views, status
from rest_framework.response import Response
from rest_framework.permissions import IsAdminUser

from .models import GMXPosition, ProtocolState
from .serializers import GMXPositionSerializer, HeartbeatSerializer, UpdateBasketWeightSerializer
from .services import OnChainService 

log = structlog.get_logger(__name__)

class GMXPositionViewSet(viewsets.ModelViewSet):
    """
    API endpoint for admins to manage GMX positions.
    """
    queryset = GMXPosition.objects.all()
    serializer_class = GMXPositionSerializer
    permission_classes = [IsAdminUser]

class SetHeartbeatView(views.APIView):
    """
    API endpoint for admins to set the heartbeat interval.
    """
    permission_classes = [IsAdminUser]

    def post(self, request, *args, **kwargs):
        state, _ = ProtocolState.objects.get_or_create(pk="a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11") # Singleton ID
        serializer = HeartbeatSerializer(instance=state, data=request.data)
        if serializer.is_valid():
            serializer.save()
            log.info("Heartbeat updated", seconds=serializer.data['seconds'])
            
            # Call the data fetcher AI agent API
            try:
                ai_agent_url = settings.DATA_FETCHER_AI_AGENT_API_URL
                if ai_agent_url:
                    requests.post(ai_agent_url, json=serializer.data, timeout=5)
            except requests.RequestException as e:
                log.error("Failed to notify AI data fetcher", error=e)

            return Response(serializer.data, status=status.HTTP_200_OK)
        return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)

class TriggerUpdateWeightsView(views.APIView):
    """
    API endpoint for admins to trigger a rebalancing weight update.
    """
    permission_classes = [IsAdminUser]

    def post(self, request, *args, **kwargs):
        log.info("Admin triggered weight update process.")
        serializer = UpdateBasketWeightSerializer(data=request.data)
        if not serializer.is_valid():
            return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)

        validated_data = serializer.validated_data
        basket_index = validated_data['basketIndex']
        new_weight_bps = validated_data['newWeightBps']
        
        try:
            onchain_service = OnChainService()
            onchain_service.update_basket_weight(basket_index, new_weight_bps)
            
            return Response({
                "status": "Weight update process triggered successfully.",
                "basketIndex": basket_index,
                "newWeightBps": new_weight_bps,
            }, status=status.HTTP_200_OK)
        except Exception as e:
            log.error("Failed to trigger weight update", error=str(e), exc_info=True)
            return Response({"error": "An error occurred during the on-chain call."}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)