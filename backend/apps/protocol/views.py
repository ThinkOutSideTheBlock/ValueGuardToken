import requests
import structlog
from django.conf import settings
from rest_framework import viewsets, views, status
from rest_framework.response import Response
from rest_framework.permissions import IsAdminUser

from .models import GMXPosition, ProtocolState
from .serializers import GMXPositionSerializer, HeartbeatSerializer, UpdateBasketWeightSerializer
from .services import OnChainService 
from drf_spectacular.utils import extend_schema 

log = structlog.get_logger(__name__)

@extend_schema(tags=['Protocol'])
class GMXPositionViewSet(viewsets.ModelViewSet):
    """
    API endpoint for admins to manage GMX positions.
    """
    queryset = GMXPosition.objects.all()
    serializer_class = GMXPositionSerializer
    permission_classes = [IsAdminUser]

@extend_schema(tags=['Protocol'])
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
            log.info("Heartbeat updated", seconds=serializer.data['heartbeatSeconds'])
            
            # Call the data fetcher AI agent API
            try:
                ai_agent_url = settings.DATA_FETCHER_AI_AGENT_API_URL
                if ai_agent_url:
                    requests.post(ai_agent_url, json=serializer.data, timeout=5)
            except requests.RequestException as e:
                log.error("Failed to notify AI data fetcher", error=e)

            return Response(serializer.data, status=status.HTTP_200_OK)
        return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)

@extend_schema(tags=['Protocol'])
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

            # --- FULLY IMPLEMENTED WEIGHT VALIDATION ---
            
            # 1. Get current total weights
            current_total_weights = onchain_service.get_total_basket_weights()
            log.info("Current total weight BPS.", total_weights=current_total_weights)

            # 2. Get the specific allocation being updated to find its old weight
            allocation_data = onchain_service.get_basket_allocation(basket_index)
            # The allocation data is a tuple. targetWeightBps is the 4th element (index 3).
            old_weight_bps = allocation_data[3]
            log.info("Found old weight for index.", index=basket_index, old_weight=old_weight_bps)

            # 3. Calculate the new total weight
            new_total_weights = (current_total_weights - old_weight_bps) + new_weight_bps
            log.info("Calculated new total weight.", new_total=new_total_weights)
            
            # 4. Validate that the new total is exactly 10000 (100%)
            if new_total_weights != 10000:
                error_message = f"Invalid total weight. The new total would be {new_total_weights}, but it must be 10000."
                log.warning(error_message)
                return Response({"error": error_message}, status=status.HTTP_400_BAD_REQUEST)

            # --- END VALIDATION ---

            # If validation passes, send the transaction
            tx_hash = onchain_service.update_basket_weight(basket_index, new_weight_bps)
            
            return Response({
                "status": "Weight update transaction sent successfully.",
                "transactionHash": tx_hash,
                "basketIndex": basket_index,
                "newWeightBps": new_weight_bps,
            }, status=status.HTTP_200_OK)
            
        except Exception as e:
            # This will catch both validation errors (e.g., invalid index) and transaction errors
            error_message = f"An error occurred: {str(e)}"
            log.error("Failed to trigger weight update", error=error_message, exc_info=True)
            return Response({"error": error_message}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)