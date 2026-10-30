> Payment validation is currently optional and disabled by default. Authenticated
> users can sign in, check availability, and book without Zoho configuration or
> payment checks. Clerk authentication is still required. To enable the payment
> rules described below later, set `PAYMENT_VALIDATION_ENABLED=true` and restart
> the API after configuring Zoho and plan validity policies. When disabled, login
> reports `payment_verification: "disabled"` and does not classify users as paid members.

# Backend V1

Clerk login/signup and Zoho payment access are implemented. Start with
[AUTH_PAYMENTS.md](AUTH_PAYMENTS.md) for required configuration, migrations,
payment import, worker startup and access policies. The booking walkthrough below
uses local demo authentication: set `AUTH_MODE=development` only for that walkthrough.
Production uses `AUTH_MODE=clerk` and requires configured payment validity rules.

# Run and test the booking API

Python FastAPI and PostgreSQL. Start with the steps below; all commands run from `backend/`.

## 1. First setup (once)

Install Python 3.14 and Docker Desktop if missing. Open Docker Desktop and wait until it is running.

```bash
cd /Users/megavannank/Desktop/projects/app/elitehealthclub/backend
python3 -m venv ../.venv
source ../.venv/bin/activate
pip install -r requirements-dev.lock
cp .env.example .env
docker compose up -d db --wait
python -m app.manage migrate
python -m app.manage seed
```

If `.env` already exists, keep it instead of running the copy command again. This project has already been set up locally; next time use section 2.

`migrate` creates/updates the schema. It is safe to repeat. `migrate` also adds new facilities to existing installations. `seed` safely restores missing catalog entries without changing existing policies. The catalog contains 13 resources, including the existing outdoor court and three suites.

## 2. Start it each day

```bash
cd /Users/megavannank/Desktop/projects/app/elitehealthclub/backend
source ../.venv/bin/activate
docker compose up -d db --wait
python -m app.manage migrate
uvicorn app.main:app --reload --host 127.0.0.1 --port 8000
```

Leave that terminal running. Open **http://127.0.0.1:8000/docs** for the interactive API tester. Press `Ctrl+C` in the terminal to stop the API.

## 3. Try your first booking in the browser

Open a second terminal:

```bash
cd /Users/megavannank/Desktop/projects/app/elitehealthclub/backend
source ../.venv/bin/activate
python -m app.manage token --user demo-member
```

Copy the printed token. In `/docs`, click **Authorize**, paste the token (without the word `Bearer`), and click **Authorize** again. Tokens last one hour; generate another when needed.

1. Expand `GET /v1/resources`, click **Try it out**, then **Execute**.
2. Expand `POST /v1/bookings`, click **Try it out**.
3. Set the `Idempotency-Key` header to `my-first-booking`.
4. Use this body, changing `date` to a future date within the next 365 days:

```json
{
  "resource_id": "outdoor-court",
  "date": "2026-11-10",
  "start_time": "10:00",
  "duration_unit": "hourly",
  "duration": 2
}
```

5. Click **Execute**. Expect **201** and a booking ID.
6. Execute again with the same body and key: expect **200** and the same booking ID.
7. Change only the key to `my-second-booking`: expect **409** because the resource is already booked.
8. Copy the ID into `POST /v1/bookings/{booking_id}/cancel` to cancel it. Repeating cancellation is safe. A new booking after cancellation needs a new key.

For a daily booking, omit `start_time`:

```json
{
  "resource_id": "suite-1",
  "date": "2026-11-10",
  "duration_unit": "daily",
  "duration": 2
}
```

That reserves midnight on November 10 through midnight on November 12 in `Asia/Kolkata`. Responses use UTC (`Z`), so 10:00 India time is 04:30 UTC. Daily bookings are calendar days, not hotel check-in/check-out stays.

## 4. Run automated tests

The API does not need to be running. PostgreSQL must be running.

```bash
cd /Users/megavannank/Desktop/projects/app/elitehealthclub/backend
source ../.venv/bin/activate
docker compose up -d db --wait
pytest -q
```

Tests use **`elitehealthclub_test`**, never the normal application database. They reset the tables in that test database. Only point `TEST_DATABASE_URL` at a disposable test database; its name must end with `_test`. Run one test suite at a time against it.

Coverage includes simultaneous users competing for one slot, simultaneous identical retries, partial/full overlaps, adjacent bookings, midnight crossings, hourly/daily collisions, cancelled slot reuse, separate suites, invalid dates/durations, missing authentication, ownership, and cancellation rules. These tests use real PostgreSQL, not a substitute database.

To test the running API from a terminal, keep section 2 running, then run:

```bash
export TOKEN="$(python -m app.manage token --user smoke-test-member)"
python scripts/smoke.py
```

Expect `PASS`. This creates a court booking seven days ahead at 10:00, checks retries and conflicts, then cancels it. If that slot is already occupied, use another time in `scripts/smoke.py`. This script is for development/staging because it creates real bookings.

Your repeatable cycle is: **start database → start API → edit code → run `pytest -q` → try `/docs`**. The development server reloads after code changes.

## API reference

All `/v1` routes require `Authorization: Bearer <token>`.

| Method | Route | Purpose |
| --- | --- | --- |
| GET | `/health/live` | Process is alive |
| GET | `/health/ready` | Database and resource table are accessible |
| GET | `/v1/resources` | Active resources and supported duration units |
| POST | `/v1/availability` | Check a proposed interval using the same body as booking |
| POST | `/v1/bookings` | Create; requires `Idempotency-Key` |
| GET | `/v1/bookings?limit=20&offset=0` | Your bookings, newest first, including cancelled |
| GET | `/v1/bookings/{id}` | Your booking details |
| POST | `/v1/bookings/{id}/cancel` | Cancel your future booking |

| Status | Meaning |
| --- | --- |
| 201 | New booking confirmed |
| 200 | Read, cancellation, or identical retry |
| 401 | Missing, invalid, or expired token |
| 404 | Unknown resource or booking; also hides another member's bookings |
| 409 | Slot conflict, inactive resource, started cancellation, or reused key with different body |
| 422 | Invalid request, unsupported unit, past date, or booking too far ahead |
| 503 | Database busy/unavailable; wait and retry with the same key and body |

Errors use `detail`; request-validation errors contain a list of field errors. Do not automatically retry 409/422 errors. On network failures or 503, retry with a bounded backoff and the original key.

## Booking rules and collision protection

- One exclusive reservation per physical resource at a time. Basketball, badminton and tennis each have one independent court. Three suites can be occupied independently. The existing outdoor court is retained for compatibility.
- Hourly durations from 0.5–24 hours in 0.5-hour increments, starting only at HH:00 or HH:30 with zero seconds, or whole calendar days from 1–30. Daily requests cannot contain `start_time`.
- Start must be in the future and within 365 days (`MAX_ADVANCE_DAYS`); a booking may end after that horizon. No backdated bookings. Hourly reservations may cross midnight.
- Times are interpreted in the resource's timezone; seeds use `Asia/Kolkata`. UTC is stored. Missing/ambiguous local start times across daylight-saving changes are rejected.
- Intervals include the start and exclude the end: 10:00–11:00 and 11:00–12:00 can coexist.
- PostgreSQL's exclusion constraint rejects overlaps inside the transaction, across API workers and servers. Availability is a snapshot; only the booking response confirms a reservation.
- Every create requires a key (1–128 ASCII letters, numbers, `.`, `_`, `:`, `-`). Generate a UUID once per booking attempt. Reuse it only for retries. Keys are scoped to the authenticated member and retained with the booking. Same key + different body gives 409. Same key after cancellation returns the cancelled booking, without reserving again.
- User identity comes from the verified token, never from request JSON. Members can read/cancel only their bookings. Started bookings cannot be cancelled. Cross-resource overlaps for one member are allowed.
- Bookings are confirmed immediately. This version has no checkout creation, temporary holds, recurring reservations, opening calendars, maintenance blocks or capacity-based pool/gym access. Clerk mode requires validated paid eligibility; see AUTH_PAYMENTS.md. Add those explicit club policies before offering those features.

## Production deployment

The booking core is ready for staging validation. Deployment and member sign-in integration remain required before public launch.

1. Provision a persistent PostgreSQL 18 database with encrypted connections, backups, and restore testing. The migration needs permission to install `btree_gist`; your database administrator can install it first. Use a separate restricted application role for runtime access (read resources; read/insert/update bookings; no schema changes).
2. Set production `DATABASE_URL` (provider URL with TLS), `JWT_SECRET`, `JWT_ISSUER`, `JWT_AUDIENCE`, and `CORS_ORIGINS` through your hosting service's secret/environment settings. Generate a secret with `python -c 'import secrets; print(secrets.token_urlsafe(48))'`. Never use `.env.example` credentials in production or expose the signing secret to the website/browser.
3. Configure Clerk and Zoho using AUTH_PAYMENTS.md. Local token generation requires development mode; production accepts Clerk RS256 sessions and enforces paid access.
4. Build the container from this directory: `docker build -t elitehealthclub-api .`. Run `python -m app.manage migrate` once as a release job using migration credentials, then start the image with runtime credentials. For a local container check: `docker compose build api`, `docker compose run --rm api python -m app.manage migrate`, `docker compose up -d api`. Stop your local Uvicorn first so port 8000 is free. Compose contains local development credentials and is not a production deployment configuration.
5. Use a host with HTTPS, process restarts, request/body limits, rate limiting, and logs/alerts for 5xx responses and database errors. Configure `/health/live` and `/health/ready` as probes. Each API process uses up to 10 database connections; size replicas accordingly. Use the default one process per container; scale containers as needed. No in-memory booking locks are required.
6. Confirm actual resource availability, opening hours, booking horizon, cancellation policy, suite check-in/out, and member eligibility. Seed examples only where appropriate. Test in staging, then run the automated suite against a separate staging test database. Wire the website's booking UI to these routes after sign-in integration.

`requirements.lock` pins runtime dependencies; `requirements-dev.lock` pins the tested development environment. The unpinned-range input files are for deliberate upgrades: install them in a clean environment, regenerate locks, and rerun the suite before deploying an update.

## Troubleshooting and stopping

- **Cannot connect to Docker:** open Docker Desktop, wait, then retry `docker compose up -d db --wait`.
- **Database connection refused:** run `docker compose ps`; PostgreSQL is mapped to local port **5433**.
- **Test database missing on an older volume:** run `docker compose exec db createdb -U ehc elitehealthclub_test` once. The initialization SQL runs only on a fresh volume.
- **401:** issue a fresh token and authorize again.
- **409:** try an available interval or cancel your earlier booking. Do not change keys to work around a real conflict.
- **Port 8000 in use:** stop the existing API, or use `--port 8001` and visit that port in your browser.
- **Stop database:** `docker compose stop`. **Restart:** `docker compose up -d db --wait`. Bookings persist in the Docker volume. Avoid `docker compose down -v` because it deletes the database volume.

References: [PostgreSQL range exclusion constraints](https://www.postgresql.org/docs/current/rangetypes.html#RANGETYPES-CONSTRAINT), [FastAPI container deployment](https://fastapi.tiangolo.com/deployment/docker/).


## Facility dropdown and booking flow

Use `GET /v1/resources` to populate the dropdown. Each resource includes `allowed_units`, `preferred_unit`, timezone, hourly start step (30 minutes), hourly duration step (0.5 hours), and maximum durations. Select `preferred_unit` initially; only offer supported units.

| Facility IDs | Policy |
| --- | --- |
| `swimming-pool`, `sauna`, `steam-bath` | Hourly, minimum 30 minutes |
| `basketball`, `badminton`, `tennis` | Hourly, one court per sport |
| `suite-1`, `suite-2`, `suite-3` | Whole calendar days, one room per entry |
| `conference-hall`, `meeting-room`, `workspaces` | Whole calendar days |
| `outdoor-court` | Existing hourly/daily resource |

Collect the local date, start time for hourly reservations, and duration. `duration: 0.5` means 30 minutes and `duration: 1.5` means 90 minutes for hourly requests. Daily durations are whole days and omit `start_time`. Check `POST /v1/availability`, then confirm with the same body at `POST /v1/bookings` and a new idempotency key. A 409 at confirmation means the interval is occupied; let the user select another time. Availability does not hold a slot.

Pool, sauna, steam bath and workspaces each use one exclusive reservation at a time, rather than per-person or per-desk capacity. Suites retain midnight calendar-day boundaries. The backend supports the requested selection flow; the website form is a separate integration.

For an existing installation, run `python -m app.manage migrate` before restarting the API. Existing bookings are preserved, including any historical start times outside the new grid; the stricter grid applies to new API requests. Repeating migration and seeding is safe.
