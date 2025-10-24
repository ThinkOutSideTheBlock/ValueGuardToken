from django.db import models
import uuid

class GMXPosition(models.Model):
    """
    Stores GMX position IDs that the protocol is actively managing.
    Managed by an admin via an API for now.
    """
    position_id = models.CharField(max_length=66, primary_key=True, help_text="The unique position ID from GMX.")
    is_closed = models.BooleanField(default=False, help_text="Marks if the position has been closed.")
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    def __str__(self):
        return self.position_id

class IntentStatus(models.TextChoices):
    PENDING = 'PENDING', 'Pending'
    PROCESSED = 'PROCESSED', 'Processed'
    FAILED = 'FAILED', 'Failed'
    EXPIRED = 'EXPIRED', 'Expired'

class MintIntent(models.Model):
    """
    Stores data from the Vault contract's MintIntentCreated event.
    """
    intent_id = models.CharField(max_length=66, primary_key=True, help_text="The unique intent ID from the event.")
    user = models.CharField(max_length=42, db_index=True)
    deposit_asset = models.CharField(max_length=42)
    deposit_amount = models.DecimalField(max_digits=78, decimal_places=18)
    locked_nav = models.DecimalField(max_digits=78, decimal_places=18)
    expected_shield = models.DecimalField(max_digits=78, decimal_places=18)
    execution_fee = models.DecimalField(max_digits=78, decimal_places=18)
    expires_at = models.BigIntegerField()
    created_at = models.DateTimeField(auto_now_add=True)

    status = models.CharField(
        max_length=10,
        choices=IntentStatus.choices,
        default=IntentStatus.PENDING,
        db_index=True
    )

    def __str__(self):
        return f"{self.intent_id} ({self.status})"

class RedeemIntent(models.Model):
    """
    Stores data from the Vault contract's RedeemIntentCreated event.
    """
    intent_id = models.CharField(max_length=66, primary_key=True, help_text="The unique intent ID from the event.")
    user = models.CharField(max_length=42, db_index=True)
    output_asset = models.CharField(max_length=42)
    shield_amount = models.DecimalField(max_digits=78, decimal_places=18)
    locked_nav = models.DecimalField(max_digits=78, decimal_places=18)
    expected_stablecoin = models.DecimalField(max_digits=78, decimal_places=18)
    execution_fee = models.DecimalField(max_digits=78, decimal_places=18)
    expires_at = models.BigIntegerField()
    created_at = models.DateTimeField(auto_now_add=True)

    status = models.CharField(
        max_length=10,
        choices=IntentStatus.choices,
        default=IntentStatus.PENDING,
        db_index=True
    )

    def __str__(self):
        return f"{self.intent_id} ({self.status})"

class ProtocolState(models.Model):
    """
    A singleton-like model to store global protocol state variables.
    """
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    heartbeat_seconds = models.PositiveIntegerField(default=300, help_text="Heartbeat interval for the AI data fetcher.")
    # Add other global settings here as needed

    def __str__(self):
        return "Protocol State"

    class Meta:
        verbose_name_plural = "Protocol State"

class BasketAllocationUpdate(models.Model):
    """
    Logs each time the BasketAllocationUpdated event is emitted from the BasketManager.
    """
    transaction_hash = models.CharField(max_length=66, primary_key=True, help_text="The transaction hash of the event.")
    basket_index = models.PositiveIntegerField()
    old_weight_bps = models.PositiveSmallIntegerField()
    new_weight_bps = models.PositiveSmallIntegerField()
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"Basket {self.basket_index}: {self.old_weight_bps} -> {self.new_weight_bps}"

    class Meta:
        ordering = ['-created_at']

class EventListenerState(models.Model):
    """
    Stores the state of the event listener, such as the last block it processed.
    This ensures that no events are missed if the listener restarts.
    """
    id = models.PositiveSmallIntegerField(primary_key=True, default=1, editable=False)
    last_processed_block = models.PositiveIntegerField()

    def __str__(self):
        return f"Event Listener State (Last Block: {self.last_processed_block})"
    
class NAVUpdateLog(models.Model):
    """
    Stores a historical log of each NAV calculation performed by the backend.
    """
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    total_position_size = models.DecimalField(max_digits=78, decimal_places=18)
    onchain_tx_hash = models.CharField(max_length=66, null=True, blank=True, help_text="Tx hash of the on-chain NAV update.")
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"NAV Update: {self.total_position_size} at {self.created_at}"

    class Meta:
        ordering = ['-created_at']


class DepositProcessedEvent(models.Model):
    """Logs DepositProcessed events from the BasketManager."""
    transaction_hash = models.CharField(max_length=66, primary_key=True)
    deposit_id = models.PositiveBigIntegerField(db_index=True)
    user = models.CharField(max_length=42, db_index=True)
    amount = models.DecimalField(max_digits=78, decimal_places=18)
    success = models.BooleanField()
    created_at = models.DateTimeField(auto_now_add=True)

class WithdrawalProcessedEvent(models.Model):
    """Logs WithdrawalProcessed events from the BasketManager."""
    transaction_hash = models.CharField(max_length=66, primary_key=True)
    withdrawal_id = models.PositiveBigIntegerField(db_index=True)
    user = models.CharField(max_length=42, db_index=True)
    amount = models.DecimalField(max_digits=78, decimal_places=18)
    success = models.BooleanField()
    created_at = models.DateTimeField(auto_now_add=True)

class RebalanceExecutedEvent(models.Model):
    """Logs RebalanceExecuted events from the BasketManager."""
    transaction_hash = models.CharField(max_length=66, primary_key=True)
    from_token = models.CharField(max_length=42)
    to_token = models.CharField(max_length=42)
    amount = models.DecimalField(max_digits=78, decimal_places=18)
    timestamp = models.PositiveBigIntegerField()
    created_at = models.DateTimeField(auto_now_add=True)