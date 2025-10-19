

# Value Guard Token Backend


## ⚙️ Initial Environment Setup

**1. Clone the Project**

```bash
git clone https://github.com/ThinkOutSideTheBlock/ValueGuardToken
cd ValueGuardToken
```

**2. Install Local Dependencies**

Set up a virtual environment and install the required Python packages.

```bash
python -m venv .venv

#activate on windows:
source .venv/Scripts/activate

#activate on linux:
source .venv/bin/activate

# Install dependencies
pip install -r requirements.txt
```

**3. Initialize the Database**

```bash
python manage.py makemigrations users
python manage.py makemigrations gmx
python manage.py makemigrations crypto
python manage.py migrate
```

```bash
python manage.py makemigrations gmx --empty --name seed_commodities
```

```python
# apps/gmx/migrations/0002_seed_commodities.py

from django.db import migrations

# A list of commodities the protocol will support.
COMMODITIES_TO_ADD = [
    {'symbol': 'GOLD', 'name': 'Gold'},
    {'symbol': 'OIL', 'name': 'Crude Oil'},
    {'symbol': 'EUR', 'name': 'Euro'},
    {'symbol': 'JPY', 'name': 'Japanese Yen'},
    {'symbol': 'WHEAT', 'name': 'Wheat'},
    {'symbol': 'COPPER', 'name': 'Copper'},
]

def seed_commodities(apps, schema_editor):
    """
    This function is executed when the migration is applied.
    """
    Commodity = apps.get_model('gmx', 'Commodity')
    for item in COMMODITIES_TO_ADD:
        # Using get_or_create ensures we don't create duplicates if the script is run again.
        Commodity.objects.get_or_create(symbol=item['symbol'], defaults={'name': item['name']})

def remove_commodities(apps, schema_editor):
    """
    This function is executed when the migration is rolled back.
    """
    Commodity = apps.get_model('gmx', 'Commodity')
    Commodity.objects.filter(symbol__in=[c['symbol'] for c in COMMODITIES_TO_ADD]).delete()


class Migration(migrations.Migration):

    dependencies = [
        ('gmx', '0001_initial'),
    ]

    operations = [
        migrations.RunPython(seed_commodities, remove_commodities),
    ]
```
```bash
python manage.py migrate gmx
```

```bash
celery -A config worker -l info
```

```bash
celery -A config beat -l info
```


```bash
# Create a Superuser
python manage.py createsuperuser
```

**3. Run the Django Development Server**

```bash
python manage.py runserver
```

-   Your API will be available at `http://localhost:8000`.
-   The Django Admin panel will be at `http://localhost:8000/admin/`.
-   The API documentation is at `http://localhost:8000/api/docs/` & `http://localhost:8000/api/redoc/`.
