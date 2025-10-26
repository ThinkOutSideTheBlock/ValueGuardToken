

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

```bash
cp .env.example.dev .env
```

**3. Initialize the Database**

```bash
python manage.py makemigrations users
python manage.py makemigrations protocol
python manage.py migrate
```

```bash
# Create a Superuser
python manage.py createsuperuser
```

**3.1. Run the Django Development Server**

```bash
python manage.py runserver
```

**3.2. Build and Start All Containers**

```bash
cp .env.example.dev .env
```

```bash
ENV_FILE=.env docker-compose -f docker-compose.production.yml --env-file .env -p backend-prod up -d --build
```

-   Your home page at `http://localhost:8000`.
-   Admin dashboard will be available at `http://localhost:8000/admin-dashboard`.
-   The Django Admin panel will be at `http://localhost:8000/admin/`.
-   The API documentation is at `http://localhost:8000/api/docs/` & `http://localhost:8000/api/redoc/`.


**4. Stop and Remove All Containers**

```bash
ENV_FILE=.env docker-compose -f docker-compose.production.yml --env-file .env -p backend-prod down -v
```