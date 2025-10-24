from django.urls import path, include
from rest_framework.routers import DefaultRouter
from .views import GMXPositionViewSet, SetHeartbeatView, TriggerUpdateWeightsView

router = DefaultRouter()
router.register(r'gmx-positions', GMXPositionViewSet)

urlpatterns = [
    path('', include(router.urls)),
    path('admin/set-heartbeat/', SetHeartbeatView.as_view(), name='set-heartbeat'),
    path('admin/trigger-update-weights/', TriggerUpdateWeightsView.as_view(), name='trigger-update-weights'),
]