# apps/crypto/models.py
from django.db import models

class CryptoCurrency(models.Model):
    """
    Stores information about each cryptocurrency tracked by the system.
    """
    symbol = models.CharField(max_length=10, unique=True, help_text="The symbol of the crypto (e.g., ETH).")
    name = models.CharField(max_length=50, help_text="The full name (e.g., Ethereum).")
    current_price = models.DecimalField(max_digits=18, decimal_places=8, default=0.0, help_text="The latest price from an oracle.")
    last_price_update = models.DateTimeField(null=True, blank=True, help_text="Timestamp of the last successful price update.")

    def __str__(self):
        return f"{self.name} ({self.symbol})"

    class Meta:
        verbose_name_plural = "Cryptocurrencies"