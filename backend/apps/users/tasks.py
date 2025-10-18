from celery import shared_task
from django.core.mail import send_mail
from django.contrib.auth import get_user_model
from django.conf import settings

User = get_user_model()

@shared_task
def send_welcome_email(wallet_address):
    try:
        user = User.objects.get(pk=wallet_address)
        
        subject = 'Welcome to Value Guard Token!'
        message = f'Hi {user.email},\n\nThank you for registering on our platform. ' \
                  f'We are excited to have you with us.'
        
        from_email = getattr(settings, 'DEFAULT_FROM_EMAIL', 'no-reply@example.com')
        recipient_list = [user.email]
        send_mail(subject, message, from_email, recipient_list)
        
        return f"Welcome email sent to {user.email}"
    except User.DoesNotExist:
        return f"User with wallet address {wallet_address} does not exist."