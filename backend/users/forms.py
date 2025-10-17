from django import forms
from django.contrib.admin.forms import AdminAuthenticationForm

class WalletAdminAuthenticationForm(AdminAuthenticationForm):
    username = forms.CharField(label="Wallet Address")

    def clean_username(self):
        username = self.cleaned_data.get("username")
        if username:
            return username.lower()
        return username
