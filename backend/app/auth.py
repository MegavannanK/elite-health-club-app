from typing import Annotated
from functools import lru_cache

import jwt
import logging
import ssl
import certifi
from fastapi import Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.config import settings

bearer = HTTPBearer(auto_error=False)


def current_user(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer)],
) -> str:
    config = settings()
    try:
        if credentials is None:
            raise ValueError("Missing bearer token")
        if config.auth_mode == "clerk":
            if not config.clerk_issuer or not config.clerk_authorized_parties:
                raise HTTPException(503, "Clerk configuration required")
            key = clerk_keys(config.clerk_issuer).get_signing_key_from_jwt(credentials.credentials).key
            claims = jwt.decode(credentials.credentials, key, algorithms=["RS256"],
                issuer=config.clerk_issuer, options={"require": ["exp", "iat", "nbf", "sub", "iss"], "verify_aud": False})
            if claims.get("sts") == "pending":
                raise HTTPException(403, detail={
                    'code': 'session_pending',
                    'message': 'Complete the required sign-in steps before continuing',
                })
            party = claims.get("azp")
            if (party is None and not config.clerk_allow_missing_azp) or (party is not None and party not in config.clerk_authorized_parties):
                raise ValueError("Unauthorized client")
            if not isinstance(claims.get("sid"), str) or not claims["sid"]:
                raise ValueError("Session required")
        elif config.auth_mode == "development" and len(config.jwt_secret) >= 32:
            claims = jwt.decode(
                credentials.credentials,
                config.jwt_secret,
                algorithms=["HS256"],
                issuer=config.jwt_issuer,
                audience=config.jwt_audience,
                options={"require": ["exp", "iat", "sub", "iss", "aud"]},
            )
        else:
            raise HTTPException(503, "Authentication configuration required")
        subject = claims["sub"]
        if not isinstance(subject, str) or not subject.strip() or len(subject) > 200:
            raise ValueError("Invalid subject")
        return subject
    except jwt.PyJWKClientConnectionError:
        raise HTTPException(503, "Clerk temporarily unavailable")
    except (jwt.PyJWTError, ValueError) as exc:
        logging.getLogger(__name__).warning("Session rejected: %s", exc)
        raise HTTPException(401, "Valid bearer token required", headers={"WWW-Authenticate": "Bearer"})


@lru_cache
def clerk_keys(issuer):
    if not issuer.startswith("https://"):
        raise HTTPException(503, "Clerk issuer must use HTTPS")
    return jwt.PyJWKClient(issuer.rstrip('/') + '/.well-known/jwks.json', timeout=5, headers={"User-Agent": "EliteHealthClub/1.0"}, ssl_context=ssl.create_default_context(cafile=certifi.where()))


User = Annotated[str, Depends(current_user)]
