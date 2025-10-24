import os
import time
import secrets
from eth_account.messages import encode_defunct
from eth_account import Account
from django.utils import timezone
from datetime import timedelta

NONCE_TTL_SECONDS = int(os.getenv("NONCE_TTL_SECONDS", 300))  # 5 minutes

def generate_nonce():
    return secrets.token_urlsafe(16)

def make_message(wallet_address: str, nonce: str, issued_at: int=None) -> str:
    if issued_at is None:
        issued_at = int(time.time())
    return f"Login to ValueGuardToken\nAddress: {wallet_address.lower()}\nNonce: {nonce}\nIssuedAt: {issued_at}"

def recover_address_from_signature(message: str, signature: str) -> str:
    encoded = encode_defunct(text=message)
    try:
        addr = Account.recover_message(encoded, signature=signature)
        return addr.lower()
    except Exception as e:
        raise
