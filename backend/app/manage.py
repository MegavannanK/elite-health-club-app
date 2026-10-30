"""Explicit migrations, sample resources, and local token generation."""
import argparse
from datetime import datetime, timedelta, timezone
from pathlib import Path

import jwt
import psycopg

from app.config import settings


def migrate(url: str):
    with psycopg.connect(url) as connection:
        connection.execute("SELECT pg_advisory_xact_lock(742001)")
        connection.execute("CREATE TABLE IF NOT EXISTS schema_migrations (name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())")
        for path in sorted((Path(__file__).parent.parent / "migrations").glob("*.sql")):
            if not connection.execute("SELECT 1 FROM schema_migrations WHERE name = %s", (path.name,)).fetchone():
                connection.execute(path.read_text())
                connection.execute("INSERT INTO schema_migrations(name) VALUES (%s)", (path.name,))


def seed(url: str):
    with psycopg.connect(url) as connection:
        connection.execute((Path(__file__).parent / "resource_catalog.sql").read_text())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["migrate", "seed", "token", "sync-payments", "process-payment-events", "payment-worker"])
    parser.add_argument("--user", default="demo-member")
    args = parser.parse_args()
    config = settings()
    if args.command == "migrate":
        migrate(config.database_url)
        print("Database migrations complete")
    elif args.command == "seed":
        seed(config.database_url)
        print("Sample resources ready")
    elif args.command == 'payment-worker':
        from app.payment_worker import serve
        serve()
    elif args.command in ('sync-payments', 'process-payment-events'):
        from app.payment_worker import run
        run(args.command)
    else:
        if config.auth_mode != 'development' or len(config.jwt_secret) < 32:
            parser.error('Local tokens require AUTH_MODE=development and a strong JWT_SECRET')
        now = datetime.now(timezone.utc)
        print(jwt.encode({"sub": args.user, "iat": now, "exp": now + timedelta(hours=1), "iss": config.jwt_issuer, "aud": config.jwt_audience}, config.jwt_secret, algorithm="HS256"))


if __name__ == "__main__":
    main()
