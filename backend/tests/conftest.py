import os
from datetime import datetime, timedelta, timezone

import jwt
import psycopg
import pytest
from fastapi.testclient import TestClient
from psycopg.conninfo import conninfo_to_dict

from app.config import settings
from app.manage import migrate, seed


@pytest.fixture(scope="session")
def database_url():
    # Never silently fall back to the application database or skip DB tests.
    from dotenv import load_dotenv
    load_dotenv()
    url = os.environ.get("TEST_DATABASE_URL")
    if not url or not conninfo_to_dict(url).get("dbname", "").endswith("_test"):
        pytest.fail("Set TEST_DATABASE_URL to a dedicated database whose name ends in _test")
    if url == os.environ.get("DATABASE_URL"):
        pytest.fail("TEST_DATABASE_URL must differ from DATABASE_URL")
    os.environ["DATABASE_URL"] = url
    os.environ.setdefault("JWT_SECRET", "automated-test-secret-with-at-least-32-characters")
    os.environ["AUTH_MODE"] = "development"
    settings.cache_clear()
    migrate(url)
    migrate(url)  # Migrations must be safe to repeat.
    return url


@pytest.fixture
def client(database_url):
    with psycopg.connect(database_url) as connection:
        connection.execute("TRUNCATE bookings, resources, app_users, payments, payment_events, payment_sync_state CASCADE")
    seed(database_url)
    from app.main import app
    with TestClient(app) as client:
        yield client


@pytest.fixture
def token():
    def make(user="member-1", **overrides):
        config = settings()
        now = datetime.now(timezone.utc)
        claims = {"sub": user, "iat": now, "exp": now + timedelta(hours=1), "iss": config.jwt_issuer, "aud": config.jwt_audience}
        claims.update(overrides)
        return jwt.encode(claims, config.jwt_secret, algorithm="HS256")
    return make


@pytest.fixture
def headers(token):
    return {"Authorization": f"Bearer {token()}", "Idempotency-Key": "test-request-1"}


@pytest.fixture
def body():
    return {"resource_id": "outdoor-court", "date": (datetime.now(timezone.utc) + timedelta(days=7)).date().isoformat(), "start_time": "10:00", "duration_unit": "hourly", "duration": 2}
