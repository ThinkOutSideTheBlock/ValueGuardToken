from django.shortcuts import render

def main_page(request):
    return render(request, 'frontend/main_page.html')

def admin_dashboard_page(request):
    # The page is public, but the data fetching inside it is protected by the API
    return render(request, 'frontend/admin_dashboard.html')
