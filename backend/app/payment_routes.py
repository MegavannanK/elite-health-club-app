import hashlib
import hmac
import json
import time

from fastapi import APIRouter, HTTPException, Request

from app.auth import User
from app.config import settings
from app.membership import synchronize

router = APIRouter()


@router.post('/auth/signup', tags=['Authentication'])
@router.post('/auth/login', tags=['Authentication'])
def login(request: Request, user: User):
    return synchronize(request.app.state.pool, user)


@router.post('/webhooks/zoho-payments', status_code=202, tags=['Payments'])
async def webhook(request: Request):
    c = settings()
    if not c.zoho_webhook_secret or not c.zoho_account_id:
        raise HTTPException(503, 'Payment webhook configuration required')
    # Enforce the limit even when Content-Length is missing or inaccurate.
    body = bytearray()
    async for chunk in request.stream():
        body.extend(chunk)
        if len(body) > 262144:
            raise HTTPException(413, 'Webhook too large')
    try:
        parts = dict(item.strip().split('=', 1) for item in request.headers.get('x-zoho-webhook-signature', '').split(','))
        timestamp = parts['t']
        if abs(time.time() * 1000 - int(timestamp)) > 300000:
            raise ValueError()
        signature = hmac.new(c.zoho_webhook_secret.encode(), timestamp.encode() + b'.' + body, hashlib.sha256).hexdigest()
        if not hmac.compare_digest(signature, parts['v']):
            raise ValueError()
    except (ValueError, KeyError):
        raise HTTPException(401, 'Invalid webhook signature')
    try:
        event = json.loads(body)
        if str(event['account_id']) != c.zoho_account_id or event.get('live_mode') is not True:
            raise ValueError()
        event_id = str(event['event_id'])
        obj = event['event_object']
        payment_id = str((obj.get('payment') or obj.get('refund') or {}).get('payment_id', ''))
        if not event_id or len(event_id) > 100:
            raise ValueError()
        if not payment_id.isdigit():
            return {'status': 'ignored'}
    except (ValueError, KeyError, TypeError, AttributeError):
        raise HTTPException(400, 'Invalid payment event')
    with request.app.state.pool.connection() as connection:
        connection.execute('''INSERT INTO payment_events(event_id,payment_id) VALUES(%s,%s)
            ON CONFLICT(event_id) DO NOTHING''', (event_id, payment_id))
    return {'status': 'queued'}
