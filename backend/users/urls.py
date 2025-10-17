from django.urls import path
from .views import RequestNonceView, VerifySignatureView, ProfileView, AdminOnlyView
from rest_framework_simplejwt.views import TokenRefreshView

urlpatterns = [
    path("auth/nonce/", RequestNonceView.as_view(), name="request-nonce"),
    path("auth/verify/", VerifySignatureView.as_view(), name="verify-signature"),
    path("auth/refresh/", TokenRefreshView.as_view(), name="token-refresh"),
    path("me/", ProfileView.as_view(), name="profile"),
    path("admin-only/", AdminOnlyView.as_view(), name="admin-only"),
]
