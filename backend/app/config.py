from functools import lru_cache
from decimal import Decimal, InvalidOperation
from typing import Literal

from pydantic import Field, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")
    database_url: str
    auth_mode: Literal["clerk", "development"] = "clerk"
    jwt_secret: str = ""
    clerk_issuer: str = ""
    clerk_secret_key: str = ""
    clerk_authorized_parties: list[str] = []
    clerk_allow_missing_azp: bool = False
    zoho_account_id: str = ""
    zoho_client_id: str = ""
    zoho_client_secret: str = ""
    zoho_refresh_token: str = ""
    zoho_webhook_secret: str = ""
    payment_validation_enabled: bool = False
    payment_refresh_seconds: int = Field(default=300, ge=30)
    # Set validity_days only after approving the access start/expiry policy.
    plan_policies: dict[str, dict] = {
        "individual": {"user_type": "member", "amount": "82600.00"},
        "family": {"user_type": "member", "amount": "236000.00"},
        "early_bird": {"user_type": "guest", "amount": "2000.00"},
    }
    jwt_issuer: str = "elitehealthclub"
    jwt_audience: str = "elitehealthclub-api"
    cors_origins: list[str] = ["http://localhost:3000"]
    max_advance_days: int = Field(default=365, ge=1, le=730)

    @model_validator(mode="after")
    def validate_policies(self):
        for name, policy in self.plan_policies.items():
            try:
                amount = Decimal(str(policy['amount']))
                if not amount.is_finite() or amount <= 0 or amount.as_tuple().exponent < -2:
                    raise ValueError()
                if not name or policy.get('user_type') not in ('member', 'guest'):
                    raise ValueError()
                days = policy.get('validity_days')
                if days is not None and (type(days) is not int or not 1 <= days <= 36525):
                    raise ValueError()
                resources = policy.get('resources', [])
                if not isinstance(resources, list) or any(not isinstance(x, str) or not x for x in resources):
                    raise ValueError()
            except (KeyError, ValueError, TypeError, InvalidOperation):
                raise ValueError(f'Invalid payment policy: {name}') from None
        return self


@lru_cache
def settings() -> Settings:
    return Settings()
