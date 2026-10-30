"""Server-only provider clients. Never include provider responses/secrets in API errors."""
import json
import ssl
import certifi
from http.client import HTTPException as HTTPProtocolError
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from threading import Lock
from time import monotonic

from app.config import settings


class ProviderUnavailable(Exception):
    pass


def fetch(url, headers=None, data=None):
    try:
        req = Request(url, headers={"User-Agent": "EliteHealthClub/1.0", **(headers or {})}, data=data)
        with urlopen(req, timeout=8, context=ssl.create_default_context(cafile=certifi.where())) as response:
            result = json.load(response)
        if not isinstance(result, dict):
            raise ValueError()
        return result
    except (HTTPError, URLError, TimeoutError, ValueError, OSError, HTTPProtocolError) as exc:
        raise ProviderUnavailable("Identity/payment provider unavailable") from exc


def clerk_profile(user_id):
    from urllib.parse import quote
    config = settings()
    if not config.clerk_secret_key:
        raise ProviderUnavailable()
    profile = fetch('https://api.clerk.com/v1/users/' + quote(user_id, safe=''),
                    {"Authorization": "Bearer " + config.clerk_secret_key})
    if profile.get('id') != user_id:
        raise ProviderUnavailable()
    return profile


class Zoho:
    def __init__(self):
        self.lock = Lock()
        self.token = None
        self.expires = 0

    def access_token(self):
        c = settings()
        if not all((c.zoho_account_id, c.zoho_client_id, c.zoho_client_secret, c.zoho_refresh_token)):
            raise ProviderUnavailable()
        with self.lock:
            if not self.token or monotonic() >= self.expires:
                result = fetch('https://accounts.zoho.in/oauth/v2/token',
                    {"Content-Type": "application/x-www-form-urlencoded"},
                    urlencode(dict(grant_type='refresh_token', client_id=c.zoho_client_id,
                        client_secret=c.zoho_client_secret, refresh_token=c.zoho_refresh_token)).encode())
                if not result.get('access_token'):
                    raise ProviderUnavailable()
                self.token = result['access_token']
                self.expires = monotonic() + max(0, int(result.get('expires_in', 3600)) - 60)
            return self.token

    def get(self, path, **params):
        params['account_id'] = settings().zoho_account_id
        result = fetch('https://payments.zoho.in/api/v1/' + path + '?' + urlencode(params),
                       {'Authorization': 'Zoho-oauthtoken ' + self.access_token()})
        if result.get('code') != 0:
            raise ProviderUnavailable()
        return result

    def payment(self, payment_id):
        if not str(payment_id).isdigit():
            raise ProviderUnavailable()
        result = self.get('payments/' + str(payment_id)).get('payment')
        if not isinstance(result, dict) or str(result.get('payment_id')) != str(payment_id):
            raise ProviderUnavailable()
        return result

    def pages(self):
        for page in range(1, 10001):
            rows = self.get('payments', page=page, per_page=200).get('payments')
            if not isinstance(rows, list):
                raise ProviderUnavailable()
            yield rows
            if len(rows) < 200:
                return
        raise ProviderUnavailable('Pagination limit exceeded')


zoho = Zoho()
