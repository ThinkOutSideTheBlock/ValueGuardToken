# apps/gmx/models.py

from django.db import models
from django.utils import timezone

class Commodity(models.Model):
    """
    Stores information about each commodity supported by the protocol.
    The source of truth for commodities is the COMMODITY_PYTH_IDS list.
    """
    # The symbol is the primary key and stores the full, unambiguous Pyth identifier.
    symbol = models.CharField(
        max_length=100, 
        primary_key=True, 
        help_text="The full Pyth Network symbol (e.g., 'Metal.XAU/USD')."
    )
    
    current_price = models.DecimalField(
        max_digits=18, 
        decimal_places=8, 
        default=0.0, 
        help_text="The latest price from the oracle."
    )
    
    last_price_update = models.DateTimeField(
        null=True, 
        blank=True, 
        help_text="Timestamp of the last successful price update."
    )


    def __str__(self):
        return f"{self.symbol} ({self.current_price:,.4f}$)"

    class Meta:
        verbose_name_plural = "Commodities"
        ordering = ['symbol']


class GMXPosition(models.Model):
    """
    Represents a single perpetual position on GMX being tracked.
    """
    position_key = models.CharField(max_length=66, unique=True, help_text="The unique key of the position from the GMX contract.")
    commodity = models.ForeignKey(Commodity, on_delete=models.CASCADE, related_name="gmx_positions")
    is_long = models.BooleanField(help_text="True if the position is long, False if short.")
    size_in_usd = models.DecimalField(max_digits=24, decimal_places=8, help_text="Position size in USD.")
    collateral_in_usd = models.DecimalField(max_digits=24, decimal_places=8, help_text="Collateral value in USD.")
    average_price = models.DecimalField(max_digits=18, decimal_places=8, help_text="The average entry price of the position.")
    unrealized_pnl = models.DecimalField(max_digits=18, decimal_places=8, default=0.0, help_text="Unrealized profit or loss.")
    last_updated = models.DateTimeField(auto_now=True, help_text="Timestamp of the last update from the monitoring service.")

    def __str__(self):
        side = "Long" if self.is_long else "Short"
        return f"{self.commodity.symbol} {side} - ${self.size_in_usd:,.2f}"


class NAVHistory(models.Model):
    """
    Stores periodic snapshots of the protocol's Net Asset Value (NAV).
    (This model remains unchanged.)
    """
    SOURCE_CHOICES = [
        ('REALTIME_BACKEND', 'Real-time Backend Calculation'),
        ('ONCHAIN_ORACLE', 'On-chain Oracle Value'),
    ]
    
    nav_per_token = models.DecimalField(max_digits=18, decimal_places=8, help_text="Net Asset Value per token in USD.")
    total_assets = models.DecimalField(max_digits=24, decimal_places=8, help_text="Total value of all assets.")
    source = models.CharField(max_length=20, choices=SOURCE_CHOICES, default='REALTIME_BACKEND')
    timestamp = models.DateTimeField(default=timezone.now, db_index=True)

    def __str__(self):
        return f"NAV: ${self.nav_per_token:,.4f} at {self.timestamp.strftime('%Y-%m-%d %H:%M:%S')}"

    class Meta:
        ordering = ['-timestamp']
        verbose_name_plural = "NAV History"