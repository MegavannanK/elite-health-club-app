CREATE TABLE app_users (
 clerk_user_id text PRIMARY KEY,
 emails text[] NOT NULL DEFAULT '{}', phones text[] NOT NULL DEFAULT '{}',
 user_type text CHECK (user_type IN ('member','guest')),
 access_status text NOT NULL DEFAULT 'pending',
 payment_verification text NOT NULL DEFAULT 'pending',
 synced_at timestamptz, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE payments (
 payment_id text PRIMARY KEY,
 user_id text REFERENCES app_users(clerk_user_id),
 email text, phone text, plan text, reference text,
 amount numeric, currency text, status text NOT NULL,
 refunded numeric NOT NULL DEFAULT 0, paid_at timestamptz,
 ownership_conflict boolean NOT NULL DEFAULT false,
 validation text NOT NULL, checked_at timestamptz NOT NULL DEFAULT now(),
 valid_until timestamptz
);
CREATE INDEX payments_email ON payments(email);
CREATE INDEX payments_phone ON payments(phone);
CREATE INDEX payments_owner ON payments(user_id);
CREATE TABLE payment_events (
 event_id text PRIMARY KEY, payment_id text NOT NULL,
 received_at timestamptz NOT NULL DEFAULT now(), processed_at timestamptz,
 attempts integer NOT NULL DEFAULT 0
);
CREATE TABLE payment_sync_state (
 id integer PRIMARY KEY CHECK(id=1), completed_at timestamptz
);
