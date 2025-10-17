

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



## API

### POST `http://127.0.0.1:8000/auth/nonce/`
```json
{
    "wallet_address": "0xeaa770540d0a243b74db98b0d3a0502f8d26ea49"
}
```

Response:
```json
{
    "message": "Login to ValueGuardToken\nAddress: 0xeaa770540d0a243b74db98b0d3a0502f8d26ea49\nNonce: BKDSx4on0beQZo6KxKlHgQ\nIssuedAt: 1760706309",
    "nonce": "BKDSx4on0beQZo6KxKlHgQ"
}
```

### POST `http://127.0.0.1:8000/auth/verify/`
```json
{
    "wallet_address": "0xeaa770540d0a243b74db98b0d3a0502f8d26ea49",
    "signature": "0xa7be9f36969ee08d819f227b301852a5b5a0c3fc90aac5d1c"
}
```
Response:
```json
{
    "access": "eyJhbGcJIUzI1NiIsInR5I6IkpXVCJ9.eyJ0b2tlbl9eXIiwiZXhwIjoxNzYtjxR32aRqho",
    "refresh": "eyJhbGciOiJIUzI1NiIs5cIkpXVCJ9.eyJ0b2tloicmVmcmVza4cCI6MTc2MTMxMTn2QBRc7EDEGJk",
    "user": {
        "id": "72574486-0a09-48f6-be18-d017543b5a41",
        "wallet_address": "0xeaa770540d0a243b74db98b0d3a0502f8d26ea49",
        "display_name": "0xeaa7...ea49",
        "role": "user",
        "date_joined": "2025-10-17T12:25:39.411592Z"
    }
}
```

### POST `http://127.0.0.1:8000/auth/refresh/`

```json
{
    "refresh": "eyJhbGciOiJIUzI1sInR5cCI6IkpXVCJ9.eyJ0b2tlbl90eXBlIjcmVmIsImV4cCI6MTc2MTMxMTE1.c7EDEGJk"
}
```

Response:
```json
{
    "access": "eyJhbGciOiJIUzI1NiIR5cCI6IkpXVCJ9.eyJ0b2tlbl90NzIiwiZXMz29O_ggC2UjQCx0"
}
```
### GET `http://127.0.0.1:8000/me/`

Response:
```json
{
  "id": "72574486-0a09-48f6-be18-d017543b5a41",
  "wallet_address": "0xeaa770540d0a243b74db98b0d3a0502f8d26ea49",
  "display_name": "0xeaa7...ea49",
  "role": "user",
  "date_joined": "2025-10-17T12:25:39.411592Z"
}
```

### GET `http://127.0.0.1:8000/admin-only/`

Response:
```json
{
  "detail": "only for Django admins (is_staff & is_superuser) or staff users"
}
```