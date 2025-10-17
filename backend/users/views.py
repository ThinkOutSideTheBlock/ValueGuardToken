from rest_framework import status, permissions
from rest_framework.views import APIView
from rest_framework.response import Response
from .serializers import RequestNonceSerializer, VerifySignatureSerializer, UserSerializer
from .models import User
from .utils import generate_nonce, make_message, recover_address_from_signature, NONCE_TTL_SECONDS
from django.utils import timezone
from datetime import timedelta
from django.conf import settings
from rest_framework_simplejwt.tokens import RefreshToken

class RequestNonceView(APIView):
    permission_classes = [permissions.AllowAny]

    def post(self, request):
        serializer = RequestNonceSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        address = serializer.validated_data["wallet_address"].lower()
        nonce = generate_nonce()
        user, _ = User.objects.get_or_create(wallet_address=address)
        user.login_nonce = nonce
        user.nonce_created_at = timezone.now()
        user.save()
        # message to sign
        msg = make_message(address, nonce)
        return Response({"message": msg, "nonce": nonce})

class VerifySignatureView(APIView):
    permission_classes = [permissions.AllowAny]

    def post(self, request):
        serializer = VerifySignatureSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        address = serializer.validated_data["wallet_address"].lower()
        signature = serializer.validated_data["signature"]

        try:
            user = User.objects.get(wallet_address=address)
        except User.DoesNotExist:
            return Response({"detail": "nonce not requested"}, status=status.HTTP_400_BAD_REQUEST)

        # check nonce TTL
        if not user.login_nonce or not user.nonce_created_at:
            return Response({"detail": "nonce not found"}, status=status.HTTP_400_BAD_REQUEST)

        # TODO uncomment after debug and development
        # if timezone.now() - user.nonce_created_at > timedelta(seconds=NONCE_TTL_SECONDS):
        #     return Response({"detail": "nonce expired"}, status=status.HTTP_400_BAD_REQUEST)

        issued_at = int(user.nonce_created_at.timestamp())
        message = make_message(address, user.login_nonce,issued_at)
        try:
            recovered = recover_address_from_signature(message, signature)
        except Exception:
            return Response({"detail": "invalid signature"}, status=status.HTTP_400_BAD_REQUEST)

        if recovered != address:
            return Response({"detail": "signature does not match address"}, status=status.HTTP_400_BAD_REQUEST)

        # success: clear nonce and issue JWT (simplejwt)
        user.login_nonce = None
        user.nonce_created_at = None
        user.save()

        refresh = RefreshToken.for_user(user)
        access = str(refresh.access_token)
        refresh_token = str(refresh)

        user_data = UserSerializer(user).data
        return Response({"access": access, "refresh": refresh_token, "user": user_data})

from rest_framework.permissions import IsAuthenticated, IsAdminUser
class ProfileView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        serializer = UserSerializer(request.user)
        return Response(serializer.data)

class AdminOnlyView(APIView):
    permission_classes = [IsAuthenticated, IsAdminUser]

    def get(self, request):
        return Response({"detail": "only for Django admins (is_staff & is_superuser) or staff users"}, status=200)
