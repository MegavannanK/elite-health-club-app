CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TABLE resources (
    id text PRIMARY KEY,
    name text NOT NULL,
    timezone text NOT NULL DEFAULT 'Asia/Kolkata',
    allowed_units text[] NOT NULL CHECK (cardinality(allowed_units) > 0 AND allowed_units <@ ARRAY['hourly','daily']::text[]),
    active boolean NOT NULL DEFAULT true
);

CREATE TABLE bookings (
    id uuid PRIMARY KEY,
    resource_id text NOT NULL REFERENCES resources(id),
    user_id text NOT NULL CHECK (length(user_id) BETWEEN 1 AND 200),
    starts_at timestamptz NOT NULL,
    ends_at timestamptz NOT NULL,
    duration_unit text NOT NULL CHECK (duration_unit IN ('hourly','daily')),
    duration integer NOT NULL CHECK (duration >= 1 AND ((duration_unit = 'hourly' AND duration <= 24) OR (duration_unit = 'daily' AND duration <= 30))),
    status text NOT NULL DEFAULT 'confirmed' CHECK (status IN ('confirmed','cancelled')),
    idempotency_key text NOT NULL CHECK (length(idempotency_key) BETWEEN 1 AND 128),
    request_payload jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    cancelled_at timestamptz,
    CONSTRAINT valid_interval CHECK (starts_at < ends_at),
    CONSTRAINT valid_cancellation CHECK ((status = 'cancelled') = (cancelled_at IS NOT NULL)),
    CONSTRAINT booking_idempotency UNIQUE(user_id, idempotency_key),
    CONSTRAINT no_overlapping_bookings EXCLUDE USING gist (
        resource_id WITH =,
        tstzrange(starts_at, ends_at, '[)') WITH &&
    ) WHERE (status = 'confirmed')
);
CREATE INDEX bookings_user_created ON bookings(user_id, created_at DESC, id DESC);
