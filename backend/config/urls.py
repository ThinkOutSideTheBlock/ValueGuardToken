from django.contrib import admin
from django.urls import path, include
from django.http import HttpResponse
from django.conf import settings
from django.conf.urls.static import static

from drf_spectacular.views import SpectacularAPIView, SpectacularRedocView, SpectacularSwaggerView

# TODO: Temporary simple home page
def home(request):
    return HttpResponse("<h1>Welcome to Value Guard Token API Server</h1><br><a href='http://localhost:8000/admin'>Visit admin panel.</a>")

urlpatterns = [

    path('', include('apps.frontend.urls')),

    path('admin/', admin.site.urls),

    path('api/schema/', SpectacularAPIView.as_view(), name='schema'),
    path('api/docs/', SpectacularSwaggerView.as_view(url_name='schema'), name='swagger-ui'),
    path('api/redoc/', SpectacularRedocView.as_view(url_name='schema'), name='redoc'),

    path('api/<str:version>/', include([
        path('users/', include('apps.users.urls')),
        path('core/', include('apps.core.urls')),
        path('protocol/', include('apps.protocol.urls')),
    ])),

]

if settings.DEBUG:
    urlpatterns += static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)