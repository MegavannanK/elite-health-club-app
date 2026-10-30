"""Payment validation and ownership; all grants derive from server-fetched Zoho data."""
import re
from datetime import datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation
from time import monotonic

from fastapi import Depends, HTTPException, Request
from typing import Annotated

from app.auth import User
from app.config import settings
from app.providers import ProviderUnavailable, clerk_profile, zoho


def email(value):
    return str(value or '').strip().lower()


def phone(value):
    raw = str(value or '').strip()
    digits = re.sub(r'[^0-9]', '', raw)
    if len(digits) == 10 and not raw.startswith('+'):
        digits = '91' + digits
    return '+' + digits if 10 <= len(digits) <= 15 else ''


def contacts(profile):
    emails = sorted({email(x.get('email_address')) for x in profile.get('email_addresses', [])
                     if x.get('verification', {}).get('status') == 'verified'} - {''})
    phones = sorted({phone(x.get('phone_number')) for x in profile.get('phone_numbers', [])
                     if x.get('verification', {}).get('status') == 'verified'} - {''})
    return emails, phones


def parse_payment(p):
    meta = {}
    for item in p.get('meta_data', []):
        key = item.get('key')
        if key in meta:
            raise ValueError('Duplicate metadata')
        meta[key] = item.get('value')
    plan = str(meta.get('plan', ''))
    reference = str(meta.get('ref', ''))
    policy = settings().plan_policies.get(plan)
    amount, refunded = Decimal(str(p['amount'])), Decimal(str(p.get('amount_refunded', '0')))
    paid = datetime.fromtimestamp(int(p['date']), timezone.utc)
    if not amount.is_finite() or not refunded.is_finite() or amount <= 0 or refunded < 0:
        raise ValueError('Invalid monetary value')
    top_email, meta_email = email(p.get('receipt_email')), email(meta.get('email'))
    top_phone = phone(str(p.get('dialing_code') or '') + str(p.get('phone') or ''))
    meta_phone = phone(meta.get('phone'))
    validation = 'verified'
    if ((top_email and meta_email and top_email != meta_email) or
            (top_phone and meta_phone and top_phone != meta_phone)):
        validation = 'review'
    if (not policy or policy.get('user_type') not in ('member', 'guest') or
            amount != Decimal(str(policy.get('amount', '0'))) or
            p.get('currency') != 'INR' or not reference.startswith('EHC-') or
            p.get('reference_number') not in (None, '', reference) or
            paid > datetime.now(timezone.utc) + timedelta(minutes=5)):
        validation = 'review'
    if refunded > 0 or p.get('status') in ('refunded', 'partially_refunded', 'disputed'):
        validation = 'review'
    until = None
    if policy and policy.get('validity_days'):
        days = int(policy['validity_days'])
        if not 1 <= days <= 36525:
            raise ValueError('Invalid validity policy')
        until = paid + timedelta(days=days)
    return dict(payment_id=str(p['payment_id']), email=top_email or meta_email,
        phone=top_phone or meta_phone, plan=plan, reference=reference, amount=amount,
        currency=p.get('currency'), status=p.get('status', 'unknown'), refunded=refunded,
        paid_at=paid, validation=validation, valid_until=until)


def refresh_payment(connection, payment_id):
    # Fetch while holding a per-payment lock so older concurrent fetches cannot overwrite newer ones.
    connection.execute('SELECT pg_advisory_xact_lock(hashtextextended(%s,0))', ('payment:' + str(payment_id),))
    p = zoho.payment(payment_id)
    try:
        row = parse_payment(p)
    except (ValueError, KeyError, TypeError, InvalidOperation, OverflowError, OSError):
        # A malformed update must also revoke a previously granted record.
        connection.execute("UPDATE payments SET validation='review', checked_at=now() WHERE payment_id=%s", (str(payment_id),))
        return
    owner = connection.execute('SELECT user_id FROM payments WHERE payment_id=%s', (str(payment_id),)).fetchone()
    if owner and owner['user_id']:
        identity = connection.execute('SELECT emails,phones FROM app_users WHERE clerk_user_id=%s', (owner['user_id'],)).fetchone()
        if row['email'] not in identity['emails'] and row['phone'] not in identity['phones']:
            connection.execute('UPDATE payments SET ownership_conflict=true WHERE payment_id=%s', (str(payment_id),))
    connection.execute('''INSERT INTO payments
        (payment_id,email,phone,plan,reference,amount,currency,status,refunded,paid_at,validation,valid_until)
        VALUES (%(payment_id)s,%(email)s,%(phone)s,%(plan)s,%(reference)s,%(amount)s,%(currency)s,
                %(status)s,%(refunded)s,%(paid_at)s,%(validation)s,%(valid_until)s)
        ON CONFLICT(payment_id) DO UPDATE SET email=excluded.email,phone=excluded.phone,
            plan=excluded.plan,reference=excluded.reference,amount=excluded.amount,
            currency=excluded.currency,status=excluded.status,refunded=excluded.refunded,
            paid_at=excluded.paid_at,validation=excluded.validation,valid_until=excluded.valid_until,
            checked_at=now()''', row)


def claim(connection, user_id, emails, phones):
    # Serializes claims and identity updates, including two accounts sharing one contact.
    connection.execute('SELECT pg_advisory_xact_lock(742003)')
    connection.execute('''INSERT INTO app_users(clerk_user_id,emails,phones) VALUES(%s,%s,%s)
        ON CONFLICT(clerk_user_id) DO UPDATE SET emails=excluded.emails,phones=excluded.phones''',
        (user_id, emails, phones))
    candidates = connection.execute('''SELECT * FROM payments
        WHERE email=ANY(%s) OR phone=ANY(%s) OR user_id=%s ORDER BY payment_id FOR UPDATE''',
        (emails, phones, user_id)).fetchall()
    conflict = False
    for p in candidates:
        others = connection.execute('''SELECT 1 FROM app_users WHERE clerk_user_id<>%s AND
            ((%s<>'' AND %s=ANY(emails)) OR (%s<>'' AND %s=ANY(phones))) LIMIT 1''',
            (user_id, p['email'], p['email'], p['phone'], p['phone'])).fetchone()
        matches = p['email'] in emails or p['phone'] in phones
        if others or (p['user_id'] and p['user_id'] != user_id) or not matches:
            conflict = True
            # Hold a previously claimed payment too; never transfer its ownership.
            connection.execute("UPDATE payments SET ownership_conflict=true WHERE payment_id=%s", (p['payment_id'],))
        elif p['user_id'] is None:
            connection.execute('UPDATE payments SET user_id=%s WHERE payment_id=%s', (user_id, p['payment_id']))
    return conflict


def projection(connection, user_id, pending=False, conflict=False):
    rows = connection.execute('SELECT * FROM payments WHERE user_id=%s', (user_id,)).fetchall()
    now = datetime.now(timezone.utc)
    eligible, active = [], []
    review = conflict
    for p in rows:
        policy = settings().plan_policies.get(p['plan'])
        if p['validation'] != 'verified' or p['ownership_conflict']:
            review = True
            continue
        if p['status'] != 'succeeded' or p['refunded'] != 0 or not policy:
            continue
        if p['amount'] != Decimal(str(policy.get('amount', '0'))) or p['currency'] != 'INR':
            review = True
            continue
        duplicate = connection.execute('''SELECT 1 FROM payments WHERE reference=%s AND payment_id<>%s
            AND status='succeeded' LIMIT 1''', (p['reference'], p['payment_id'])).fetchone()
        if duplicate:
            review = True
            continue
        eligible.append((p, policy))
        if p['valid_until'] is None:
            review = True
        elif p['valid_until'] > now and p['checked_at'] > now - timedelta(hours=24):
            active.append((p, policy))
        elif p['checked_at'] <= now - timedelta(hours=24):
            pending = True
    selected = active or eligible
    kind = ('member' if any(policy['user_type'] == 'member' for _, policy in selected)
            else 'guest' if selected else None)
    status = 'active' if active else 'review' if review else 'pending' if pending else 'inactive'
    verification = 'review' if review else 'pending' if pending else 'verified' if eligible else 'not_paid'
    connection.execute('''UPDATE app_users SET user_type=%s,access_status=%s,payment_verification=%s
        WHERE clerk_user_id=%s''', (kind, status, verification, user_id))
    return dict(user_id=user_id, user_type=kind, access_status=status,
        payment_verification=verification, purchases=[dict(plan=p['plan'],
        valid_from=p['paid_at'], valid_until=p['valid_until']) for p, _ in selected])


def synchronize(pool, user_id):
    if not settings().payment_validation_enabled:
        return dict(user_id=user_id, user_type=None, access_status='active',
                    payment_verification='disabled', purchases=[])
    try:
        profile = clerk_profile(user_id)
    except ProviderUnavailable:
        raise HTTPException(503, 'Unable to verify user profile; retry shortly')
    emails, phones = contacts(profile)
    if not emails and not phones:
        raise HTTPException(403, 'Verify an email address or mobile number in Clerk first')
    with pool.connection() as connection:
        ids = connection.execute('''SELECT payment_id FROM payments WHERE
            email=ANY(%s) OR phone=ANY(%s) OR user_id=%s ORDER BY payment_id''', (emails, phones, user_id)).fetchall()
        state = connection.execute('SELECT completed_at FROM payment_sync_state WHERE id=1').fetchone()
    pending = not state or state['completed_at'] < datetime.now(timezone.utc) - timedelta(hours=24)
    # Bounded refresh keeps login responsive. Worker handles bulk reconciliation.
    with pool.connection() as connection:
        last = connection.execute('SELECT synced_at FROM app_users WHERE clerk_user_id=%s', (user_id,)).fetchone()
    due = not last or not last['synced_at'] or last['synced_at'] < datetime.now(timezone.utc) - timedelta(seconds=settings().payment_refresh_seconds)
    if due:
        deadline = monotonic() + 10
        for row in ids[:10]:
            if monotonic() > deadline:
                pending = True
                break
            try:
                with pool.connection() as connection:
                    refresh_payment(connection, row['payment_id'])
            except ProviderUnavailable:
                pending = True
                break
        if len(ids) > 10:
            pending = True
    with pool.connection() as connection:
        conflict = claim(connection, user_id, emails, phones)
        if due and not pending:
            connection.execute('UPDATE app_users SET synced_at=now() WHERE clerk_user_id=%s', (user_id,))
        return projection(connection, user_id, pending, conflict)


def paid_user(request: Request, user: User):
    if not settings().payment_validation_enabled or settings().auth_mode == 'development':
        return user
    with request.app.state.pool.connection() as connection:
        result = projection(connection, user)
    if result['access_status'] != 'active':
        raise HTTPException(403, 'Active paid access required; complete login/payment verification')
    return user


PaidUser = Annotated[str, Depends(paid_user)]


def authorize_interval(connection, user_id, resource_id, start, end):
    if not settings().payment_validation_enabled or settings().auth_mode == 'development':
        return
    result = projection(connection, user_id)
    if result['access_status'] == 'active':
        for access in result['purchases']:
            policy = settings().plan_policies[access['plan']]
            if (access['valid_until'] and access['valid_from'] <= start and end <= access['valid_until']
                    and (not policy.get('resources') or resource_id in policy['resources'])):
                return
    raise HTTPException(403, 'Booking must fall within your paid access period and eligible facilities')
