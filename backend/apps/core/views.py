from django.utils import timezone
from rest_framework.views import APIView
from rest_framework.response import Response
from django.views.decorators.cache import cache_page
from django.utils.decorators import method_decorator
from django.core.cache import cache
from rest_framework.permissions import IsAdminUser
from rest_framework import status
from drf_spectacular.utils import extend_schema, OpenApiExample
from rest_framework import serializers
from .serializers import CacheKeySerializer, CacheStatusSerializer, ErrorDetailSerializer 


@extend_schema(tags=['Core'], summary="Manage Application Cache")
class CacheManagementView(APIView):
    """
    An admin-only View for managing the application cache.
    - POST /: Clears a specific key from the cache.
    - DELETE /: Clears the entire cache.
    """
    permission_classes = [IsAdminUser]


    @extend_schema(
        summary="Clear a Specific Cache Key",
        request=CacheKeySerializer,
        responses={
            200: CacheStatusSerializer,
            400: ErrorDetailSerializer,
            404: CacheStatusSerializer,
        },
        examples=[
            OpenApiExample(
                'Clear Profile Cache Example',
                description='An example payload to clear the cache for a specific user profile.',
                value={
                    "key": "profile_by_user_id_1"
                },
                request_only=True,
            )
        ]
    )
    def post(self, request, *args, **kwargs):
        """
        Removes a specific key from the cache.
        Expects a body in the format: {"key": "profile_by_user_id_1"}.
        """
        key = request.data.get('key')
        if not key:
            return Response(
                {"error": "The 'key' field in the request body is mandatory."},
                status=status.HTTP_400_BAD_REQUEST
            )
        
        if key in cache:
            cache.delete(key)
            return Response({"status": f"Cache key '{key}' was successfully deleted."})
        else:
            return Response({"status": f"Cache key '{key}' was not found."}, status=status.HTTP_404_NOT_FOUND)

    @extend_schema(
        summary="Clear the Entire Cache",
        responses={200: CacheStatusSerializer}
    )
    def delete(self, request, *args, **kwargs):
        """
        Clears all cache content.
        """
        cache.clear()
        return Response({"status": "All cache was successfully cleared."})