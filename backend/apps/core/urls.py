# apps/core/urls.py
from django.urls import path
from .views import CacheManagementView

urlpatterns = [
    path('cache/', CacheManagementView.as_view(), name='cache-management'),
]