from django.contrib import admin
from django.contrib.auth.admin import UserAdmin as BaseUserAdmin
from .models import User
from .forms import WalletAdminAuthenticationForm
from django.contrib.auth.forms import UserChangeForm, UserCreationForm

class CustomUserAdmin(BaseUserAdmin):
    form = UserChangeForm
    add_form = UserCreationForm

    list_display = ("wallet_address", "is_staff", "is_superuser", "role")
    list_filter = ("is_staff", "is_superuser", "role")
    
    fieldsets = (
        (None, {"fields": ("wallet_address", "password")}),
        ("Permissions", {"fields": ("is_staff", "is_superuser", "role", "groups", "user_permissions")}),
    )
    add_fieldsets = (
        (None, {
            "classes": ("wide",),
            "fields": ("wallet_address", "password1", "password2", "role", "is_staff", "is_superuser"),
        }),
    )

    search_fields = ("wallet_address",)
    ordering = ("wallet_address",)
    filter_horizontal = ("groups", "user_permissions",)

admin.site.register(User, CustomUserAdmin)

admin.site.login_form = WalletAdminAuthenticationForm
