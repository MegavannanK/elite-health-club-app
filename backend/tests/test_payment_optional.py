from types import SimpleNamespace

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app import membership
from app.config import Settings
from app.payment_routes import router


def test_payment_validation_disabled_by_default():
    assert not Settings(_env_file=None, database_url='postgresql://unused').payment_validation_enabled


def test_disabled_validation_skips_providers_and_payment_storage(monkeypatch):
    monkeypatch.setattr(membership, 'settings', lambda: SimpleNamespace(
        payment_validation_enabled=False, auth_mode='clerk'))
    def unexpected(*args):
        pytest.fail('Payment-disabled access must not contact providers or storage')
    monkeypatch.setattr(membership, 'clerk_profile', unexpected)
    monkeypatch.setattr(membership.zoho, 'payment', unexpected)
    assert membership.synchronize(None, 'user-1') == dict(
        user_id='user-1', user_type=None, access_status='active',
        payment_verification='disabled', purchases=[])
    assert membership.paid_user(None, 'user-1') == 'user-1'
    membership.authorize_interval(None, 'user-1', 'tennis', None, None)


@pytest.mark.parametrize('endpoint', ['/auth/login', '/auth/signup'])
def test_disabled_payments_still_require_authentication(monkeypatch, endpoint):
    monkeypatch.setattr(membership, 'settings', lambda: SimpleNamespace(
        payment_validation_enabled=False, auth_mode='clerk'))
    app = FastAPI()
    app.include_router(router)
    with TestClient(app) as client:
        assert client.post(endpoint).status_code == 401
