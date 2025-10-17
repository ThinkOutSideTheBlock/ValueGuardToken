

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
python manage.py makemigrations
python manage.py migrate

# Create a Superuser
python manage.py createsuperuser
```

**3. Run the Django Development Server**

```bash
python manage.py runserver
```

-   Your API will be available at `http://localhost:8000`.
-   The Django Admin panel will be at `http://localhost:8000/admin/`.

