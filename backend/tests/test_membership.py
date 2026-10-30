import hashlib
import hmac
import json
import time
from datetime import datetime, timezone
from types import SimpleNamespace

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa

from app import membership
from app.auth import current_user
from app.config import settings
from app.providers import ProviderUnavailable


def payment(plan='individual', status='succeeded', payment_id='123', **changes):
    row = dict(payment_id=payment_id, amount={'individual': '82600', 'family': '236000', 'early_bird': '2000'}.get(plan, '2000'),
        currency='INR', date=int(time.time()) - 60, status=status, amount_refunded='0',
        receipt_email='member@example.com', phone='9000000001', dialing_code='+91',
        meta_data=[{'key': 'plan', 'value': plan}, {'key': 'ref', 'value': 'EHC-' + payment_id}])
    row.update(changes)
    return row


@pytest.fixture
def integration(client, monkeypatch):
    c = settings()
    monkeypatch.setattr(c, 'payment_validation_enabled', True)
    monkeypatch.setattr(c, 'plan_policies', {k: dict(v, validity_days=30) for k, v in c.plan_policies.items()})
    monkeypatch.setattr(membership, 'clerk_profile', lambda user: {'email_addresses': [
        {'email_address': 'member@example.com', 'verification': {'status': 'verified'}}], 'phone_numbers': []})
    store = {}
    monkeypatch.setattr(membership.zoho, 'payment', lambda pid: store[pid])
    def save(row):
        store[row['payment_id']] = row
        with client.app.state.pool.connection() as connection:
            membership.refresh_payment(connection, row['payment_id'])
            connection.execute('''INSERT INTO payment_sync_state(id,completed_at) VALUES(1,now())
                ON CONFLICT(id) DO UPDATE SET completed_at=now()''')
    return client, save, store


@pytest.mark.parametrize('plan,kind', [('individual','member'), ('family','member'), ('early_bird','guest')])
def test_signup_login_classification(integration, headers, plan, kind):
    client, save, _ = integration
    save(payment(plan))
    for endpoint in ['/auth/signup', '/auth/signup', '/auth/login']:
        result = client.post(endpoint, headers=headers)
        assert result.status_code == 200, result.text
        assert result.json()['user_type'] == kind
        assert result.json()['access_status'] == 'active'
    with client.app.state.pool.connection() as connection:
        assert connection.execute('SELECT count(*) AS n FROM app_users').fetchone()['n'] == 1


@pytest.mark.parametrize('status', ['failed', 'cancelled', 'pending', 'authorized'])
def test_unsuccessful_never_grants(integration, headers, status):
    client, save, _ = integration
    save(payment(status=status))
    result = client.post('/auth/signup', headers=headers).json()
    assert result['user_type'] is None
    assert result['access_status'] != 'active'


@pytest.mark.parametrize('changes', [dict(amount='1'), dict(currency='USD'), dict(amount_refunded='1'), dict(status='disputed')])
def test_invalid_payment_on_hold(integration, headers, changes):
    client, save, _ = integration
    save(payment(**changes))
    result = client.post('/auth/signup', headers=headers).json()
    assert result['access_status'] == 'review'
    assert result['user_type'] is None


def test_member_not_downgraded_and_refund_revokes(integration, headers):
    client, save, _ = integration
    save(payment())
    save(payment('early_bird', payment_id='456'))
    assert client.post('/auth/login', headers=headers).json()['user_type'] == 'member'
    save(payment(amount_refunded='82600', status='refunded'))
    assert client.post('/auth/login', headers=headers).json()['user_type'] == 'guest'
    save(payment('early_bird', payment_id='456', amount_refunded='2000', status='refunded'))
    assert client.post('/auth/login', headers=headers).json()['access_status'] != 'active'


def test_shared_contact_never_transfers_and_hold_survives_refresh(integration, headers, token):
    client, save, _ = integration
    save(payment())
    assert client.post('/auth/login', headers=headers).json()['access_status'] == 'active'
    other = {'Authorization': 'Bearer ' + token('second-user')}
    assert client.post('/auth/login', headers=other).json()['access_status'] == 'review'
    save(payment())
    assert client.post('/auth/login', headers=headers).json()['access_status'] == 'review'
    with client.app.state.pool.connection() as connection:
        assert connection.execute('SELECT user_id FROM payments').fetchone()['user_id'] == 'member-1'


def test_missing_policy_validity_requires_review(integration, headers, monkeypatch):
    client, save, _ = integration
    monkeypatch.setattr(settings(), 'plan_policies', {'individual': {'user_type': 'member', 'amount': '82600'}})
    save(payment())
    data = client.post('/auth/login', headers=headers).json()
    assert data['user_type'] == 'member'
    assert data['access_status'] == 'review'


def test_unknown_plan_and_unverified_contact(integration, headers, monkeypatch):
    client, save, _ = integration
    save(payment('unexpected'))
    assert client.post('/auth/login', headers=headers).json()['access_status'] == 'review'
    monkeypatch.setattr(membership, 'clerk_profile', lambda _: {'email_addresses': [
        {'email_address': 'member@example.com', 'verification': {'status': 'unverified'}}]})
    assert client.post('/auth/signup', headers=headers).status_code == 403


def test_provider_timeout_pending(integration, headers, monkeypatch):
    client, save, _ = integration
    save(payment())
    def unavailable(_):
        raise ProviderUnavailable()
    monkeypatch.setattr(membership.zoho, 'payment', unavailable)
    result = client.post('/auth/login', headers=headers).json()
    assert result['payment_verification'] == 'pending'
    assert result['user_type'] == 'member'


def test_clerk_booking_requires_paid_access(integration, body, headers, monkeypatch):
    client, save, _ = integration
    from app.auth import current_user
    client.app.dependency_overrides[current_user] = lambda: 'member-1'
    monkeypatch.setattr(settings(), 'auth_mode', 'clerk')
    try:
        assert client.post('/v1/bookings', json=body, headers=headers).status_code == 403
        save(payment())
        assert client.post('/auth/login', headers=headers).json()['access_status'] == 'active'
        assert client.post('/v1/bookings', json=body, headers=headers).status_code == 201
    finally:
        client.app.dependency_overrides.clear()


def signed_event(c, event, timestamp=None):
    raw = json.dumps(event).encode()
    stamp = str(timestamp or int(time.time() * 1000))
    digest = hmac.new(c.zoho_webhook_secret.encode(), stamp.encode() + b'.' + raw, hashlib.sha256).hexdigest()
    return raw, {'X-Zoho-Webhook-Signature': f't={stamp},v={digest}'}


def test_webhook_queue_dedup_and_worker(integration, monkeypatch):
    client, save, store = integration
    c = settings()
    monkeypatch.setattr(c, 'zoho_account_id', '999')
    monkeypatch.setattr(c, 'zoho_webhook_secret', 'webhook-secret')
    store['123'] = payment()
    event = {'event_id': 'evt1', 'account_id': 999, 'live_mode': True,
        'event_object': {'payment': {'payment_id': '123'}}}
    raw, headers = signed_event(c, event)
    for _ in range(2):
        assert client.post('/webhooks/zoho-payments', content=raw, headers=headers).status_code == 202
    from app.payment_worker import process_events
    assert process_events(client.app.state.pool) == 1
    assert process_events(client.app.state.pool) == 0
    assert client.post('/webhooks/zoho-payments', content=raw + b' ', headers=headers).status_code == 401
    raw, headers = signed_event(c, event, int(time.time()*1000) - 600000)
    assert client.post('/webhooks/zoho-payments', content=raw, headers=headers).status_code == 401
    event['live_mode'] = False
    raw, headers = signed_event(c, event)
    assert client.post('/webhooks/zoho-payments', content=raw, headers=headers).status_code == 400


def test_clerk_rs256_verification(client, monkeypatch):
    from app import auth
    c = settings()
    monkeypatch.setattr(c, 'auth_mode', 'clerk')
    monkeypatch.setattr(c, 'clerk_allow_missing_azp', False)
    monkeypatch.setattr(c, 'clerk_issuer', 'https://clerk.example.com')
    monkeypatch.setattr(c, 'clerk_authorized_parties', ['https://club.example.com'])
    private = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    monkeypatch.setattr(auth, 'clerk_keys', lambda _: SimpleNamespace(get_signing_key_from_jwt=lambda _: SimpleNamespace(key=private.public_key())))
    claims = dict(sub='user_1', sid='sess_1', iss=c.clerk_issuer, azp='https://club.example.com',
                  iat=int(time.time()), nbf=int(time.time())-1, exp=int(time.time())+60)
    def request(changes=None, algorithm='RS256'):
        encoded = jwt.encode(claims | (changes or {}), private if algorithm == 'RS256' else 'a'*40, algorithm=algorithm)
        return client.get('/v1/resources', headers={'Authorization': 'Bearer ' + encoded})
    assert request().status_code == 200
    assert request({'azp': 'https://evil.example.com'}).status_code == 401
    pending = request({'sts': 'pending'})
    assert pending.status_code == 403
    assert pending.json()['detail']['code'] == 'session_pending'
    assert request({'exp': 1}).status_code == 401
    assert request(algorithm='HS256').status_code == 401
    claims.pop('azp')
    assert request().status_code == 401
    monkeypatch.setattr(c, 'clerk_allow_missing_azp', True)
    assert request().status_code == 200
    assert request({'azp': 'https://evil.example.com'}).status_code == 401


def test_expired_and_outside_access_bookings(integration, body, headers, monkeypatch):
    client, save, _ = integration
    from app.auth import current_user
    client.app.dependency_overrides[current_user] = lambda: 'member-1'
    monkeypatch.setattr(settings(), 'auth_mode', 'clerk')
    try:
        save(payment())
        client.post('/auth/login', headers=headers)
        from datetime import timedelta
        distant = body | {'date': (datetime.now(timezone.utc) + timedelta(days=40)).date().isoformat()}
        assert client.post('/v1/bookings', json=distant, headers=headers).status_code == 403
        save(payment(date=int(time.time())-86400*40))
        assert client.post('/v1/bookings', json=body, headers=headers).status_code == 403
    finally:
        client.app.dependency_overrides.clear()


def test_worker_failure_is_retryable(integration, monkeypatch):
    client, _, store = integration
    from app.payment_worker import process_events
    with client.app.state.pool.connection() as connection:
        connection.execute("INSERT INTO payment_events(event_id,payment_id) VALUES('event1','123')")
    def unavailable(_):
        raise ProviderUnavailable()
    original = membership.zoho.payment
    monkeypatch.setattr(membership.zoho, 'payment', unavailable)
    assert process_events(client.app.state.pool) == 0
    with client.app.state.pool.connection() as connection:
        row = connection.execute('SELECT * FROM payment_events').fetchone()
        assert row['attempts'] == 1 and row['processed_at'] is None
    monkeypatch.setattr(membership.zoho, 'payment', original)
    store['123'] = payment()
    assert process_events(client.app.state.pool) == 1


def test_changed_owner_and_malformed_update_hold_access(integration, headers):
    client, save, _ = integration
    save(payment())
    assert client.post('/auth/login', headers=headers).json()['access_status'] == 'active'
    save(payment(receipt_email='other@example.com', phone='9000000002'))
    assert client.post('/auth/login', headers=headers).json()['access_status'] == 'review'
    save(payment(amount='NaN'))
    assert client.post('/auth/login', headers=headers).json()['access_status'] != 'active'


def test_duplicate_reference_needs_review(integration, headers):
    client, save, _ = integration
    one = payment()
    save(one)
    save(payment(payment_id='456', meta_data=one['meta_data']))
    assert client.post('/auth/login', headers=headers).json()['access_status'] == 'review'


def test_reconciliation_paginates_and_only_marks_complete(integration, monkeypatch):
    client, _, store = integration
    from app.payment_worker import reconcile
    store['123'], store['456'] = payment(), payment('early_bird', payment_id='456')
    monkeypatch.setattr(membership.zoho, 'pages', lambda: iter([[{'payment_id': '123'}], [{'payment_id': '456'}]]))
    assert reconcile(client.app.state.pool) == 2
    with client.app.state.pool.connection() as connection:
        assert connection.execute('SELECT count(*) AS n FROM payments').fetchone()['n'] == 2
        connection.execute('DELETE FROM payment_sync_state')
    def fail():
        yield [{'payment_id': '123'}]
        raise ProviderUnavailable()
    monkeypatch.setattr(membership.zoho, 'pages', fail)
    with pytest.raises(ProviderUnavailable):
        reconcile(client.app.state.pool)
    with client.app.state.pool.connection() as connection:
        assert connection.execute('SELECT * FROM payment_sync_state').fetchone() is None


def test_webhook_worker_updates_database_user_type(integration, headers):
    client, save, store = integration
    save(payment())
    assert client.post('/auth/login', headers=headers).json()['user_type'] == 'member'
    store['123'] = payment(status='refunded', amount_refunded='82600')
    with client.app.state.pool.connection() as connection:
        connection.execute("INSERT INTO payment_events(event_id,payment_id) VALUES('refund1','123')")
    from app.payment_worker import process_events
    assert process_events(client.app.state.pool) == 1
    with client.app.state.pool.connection() as connection:
        user = connection.execute('SELECT * FROM app_users').fetchone()
        assert user['user_type'] is None
        assert user['access_status'] == 'review'
