import json
from pathlib import Path
from django.conf import settings

def load_abi(name: str):
    """Loads a contract ABI from the /abi/ directory."""
    abi_path = Path(settings.BASE_DIR) / "abi" / f"{name}.json"
    if not abi_path.exists():
        raise FileNotFoundError(f"ABI file not found at: {abi_path}")
    with open(abi_path, 'r') as f:
        return json.load(f)