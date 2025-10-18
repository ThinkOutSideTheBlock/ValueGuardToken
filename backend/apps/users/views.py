from rest_framework import status, permissions
from rest_framework.views import APIView
from rest_framework.response import Response
from .serializers import (
    RequestNonceSerializer, 
    VerifySignatureSerializer, 
    UserSerializer,
    NonceResponseSerializer,          
    VerifySignatureResponseSerializer,  
    AccessTokenResponseSerializer,    
)
from .models import User
from .utils import generate_nonce, make_message, recover_address_from_signature, NONCE_TTL_SECONDS
from django.utils import timezone
from datetime import timedelta
from django.conf import settings
from rest_framework.permissions import IsAuthenticated, IsAdminUser
from rest_framework_simplejwt.tokens import RefreshToken
from drf_spectacular.utils import extend_schema, OpenApiResponse
from rest_framework_simplejwt.views import TokenRefreshView
from rest_framework_simplejwt.serializers import TokenRefreshSerializer


@extend_schema(
    tags=['Authentication'],
    summary="Step 1: Request a Nonce",
    description="Initiates the login process by requesting a unique message (nonce) to be signed by the user's wallet.",
    request=RequestNonceSerializer,  
    responses={
        status.HTTP_200_OK: NonceResponseSerializer, 
    }
)
class RequestNonceView(APIView):
    permission_classes = [permissions.AllowAny]

    def post(self, request, *args, **kwargs):
        serializer = RequestNonceSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        address = serializer.validated_data["wallet_address"].lower()
        nonce = generate_nonce()
        user, _ = User.objects.get_or_create(wallet_address=address)
        user.login_nonce = nonce
        user.nonce_created_at = timezone.now()
        user.save()
        msg = make_message(address, nonce)
        # Use the serializer for consistent output
        response_serializer = NonceResponseSerializer(data={"message": msg, "nonce": nonce})
        response_serializer.is_valid(raise_exception=True)
        return Response(response_serializer.data, status=status.HTTP_200_OK)

@extend_schema(
    tags=['Authentication'],
    summary="Step 2: Verify Signature and Get Tokens",
    description="Verifies the signed message and returns JWT access and refresh tokens upon success.",
    request=VerifySignatureSerializer,
    responses={
        status.HTTP_200_OK: VerifySignatureResponseSerializer, 
        status.HTTP_400_BAD_REQUEST: OpenApiResponse(description="Invalid input, signature, or expired nonce."),
    }
)
class VerifySignatureView(APIView):
    permission_classes = [permissions.AllowAny]

    def post(self, request, *args, **kwargs):
        serializer = VerifySignatureSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        address = serializer.validated_data["wallet_address"].lower()
        signature = serializer.validated_data["signature"]

        try:
            user = User.objects.get(wallet_address=address)
        except User.DoesNotExist:
            return Response({"detail": "Nonce not requested for this address."}, status=status.HTTP_400_BAD_REQUEST)

        if not user.login_nonce or not user.nonce_created_at:
            return Response({"detail": "Nonce not found for this user."}, status=status.HTTP_400_BAD_REQUEST)

        # TODO: Uncomment after debug and development
        # if timezone.now() - user.nonce_created_at > timedelta(seconds=NONCE_TTL_SECONDS):
        #     return Response({"detail": "Nonce has expired."}, status=status.HTTP_400_BAD_REQUEST)

        issued_at = int(user.nonce_created_at.timestamp())
        message = make_message(address, user.login_nonce, issued_at)
        
        try:
            recovered = recover_address_from_signature(message, signature)
        except Exception:
            return Response({"detail": "The provided signature is invalid."}, status=status.HTTP_400_BAD_REQUEST)

        if recovered != address:
            return Response({"detail": "Signature does not match the wallet address."}, status=status.HTTP_400_BAD_REQUEST)

        user.login_nonce = None
        user.nonce_created_at = None
        user.save()

        refresh = RefreshToken.for_user(user)
        
        user_data = UserSerializer(user).data
        response_data = {
            "access": str(refresh.access_token),
            "refresh": str(refresh),
            "user": user_data
        }
        return Response(response_data, status=status.HTTP_200_OK)

@extend_schema(
    tags=['Authentication'],
    summary="Refresh Access Token",
    description="Takes a refresh token and returns a new access token if the refresh token is valid.",
    request=TokenRefreshSerializer, # Use the default serializer from simplejwt
    responses={
        status.HTTP_200_OK: AccessTokenResponseSerializer,
        status.HTTP_401_UNAUTHORIZED: OpenApiResponse(description="Token is invalid or expired."),
    }
)
class CustomTokenRefreshView(TokenRefreshView):
    pass

@extend_schema(
    tags=['Users'],
    summary="Get User Profile",
    description="Retrieves the profile information of the currently authenticated user.",
    responses={
        status.HTTP_200_OK: UserSerializer,
        status.HTTP_401_UNAUTHORIZED: OpenApiResponse(description="Authentication credentials were not provided."),
    }
)
class ProfileView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, *args, **kwargs):
        serializer = UserSerializer(request.user)
        return Response(serializer.data)

@extend_schema(
    tags=['Debug'],
    summary="Admin-Only Endpoint",
    description="An endpoint accessible only by users with admin privileges (is_staff=True).",
    responses={
        status.HTTP_200_OK: OpenApiResponse(description="Success message for admin users."),
        status.HTTP_403_FORBIDDEN: OpenApiResponse(description="User does not have admin permissions."),
    }
)
class AdminOnlyView(APIView):
    permission_classes = [IsAuthenticated, IsAdminUser]

    def get(self, request, *args, **kwargs):
        return Response({"detail": "This is accessible only to admin users."}, status=status.HTTP_200_OK)