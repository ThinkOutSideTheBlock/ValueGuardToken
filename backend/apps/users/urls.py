from django.urls import path
from .views import CustomTokenRefreshView, RequestNonceView, VerifySignatureView, ProfileView, AdminOnlyView
from rest_framework_simplejwt.views import TokenRefreshView

urlpatterns = [
    path("auth/nonce/", RequestNonceView.as_view(), name="request-nonce"),
    path("auth/verify/", VerifySignatureView.as_view(), name="verify-signature"),
    path("me/", ProfileView.as_view(), name="profile"),
    path("admin-only/", AdminOnlyView.as_view(), name="admin-only"),
    path('auth/token/refresh/', CustomTokenRefreshView.as_view(), name='token_refresh'),
]
