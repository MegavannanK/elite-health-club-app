> Payment validation is currently optional and disabled by default. Authenticated
> users can sign in, check availability, and book without Zoho configuration or
> payment checks. Clerk authentication is still required. To enable the payment
> rules described below later, set `PAYMENT_VALIDATION_ENABLED=true` and restart
> the API after configuring Zoho and plan validity policies. When disabled, login
> reports `payment_verification: "disabled"` and does not classify users as paid members.

# V1 authentication and payment access

Clerk authenticates the user. The backend obtains verified contacts from Clerk's
server API and verifies payments through the **live India Zoho Payments account**.
No browser-supplied email, user type, payment ID or success flag grants access.

## Configuration and startup

Run commands from `backend/` with the virtual environment active.

1. Install `pip install -r requirements-dev.lock`.
2. Configure `.env` using `.env.example`. Keep `AUTH_MODE=clerk` for real sign-in.
   Set `CLERK_ISSUER`, `CLERK_SECRET_KEY`, and `CLERK_AUTHORIZED_PARTIES` to your
   Clerk instance and allowed client origins. For native Clerk sessions that omit
   `azp`, explicitly set `CLERK_ALLOW_MISSING_AZP=true`; present `azp` values must
   still match the allowlist. HS256 demo tokens are rejected in Clerk mode.
3. Set `ZOHO_ACCOUNT_ID`, `ZOHO_CLIENT_ID`, `ZOHO_CLIENT_SECRET`,
   `ZOHO_REFRESH_TOKEN`, and `ZOHO_WEBHOOK_SECRET`. OAuth needs
   `ZohoPay.payments.READ`. Never put secrets in the mobile app.
4. Run `python -m app.manage migrate` with migration credentials.
5. Run `python -m app.manage sync-payments` for the initial import.
6. Start API: `uvicorn app.main:app --host 127.0.0.1 --port 8000`.
7. Start a separate persistent worker: `python -m app.manage payment-worker`.
   It processes queued events every five seconds and reconciles all payments at
   startup and hourly. Give it restart supervision. It uses up to ten DB connections,
   independently of the API. Failed imports do not mark reconciliation complete;
   failed event fetches remain queued. Alert on old pending events or stale sync state.
8. Configure Zoho's HTTPS webhook URL to `/webhooks/zoho-payments` and subscribe
   to payment, refund and dispute notifications supported by your account.

One-pass alternatives for a scheduler: `python -m app.manage process-payment-events`
and `python -m app.manage sync-payments`. Run migrations before API/worker deployment.
Provider calls have timeouts; provider failure never becomes payment failure.

## Required club policy before enabling bookings

Default plan prices match the website: `individual` INR 82600, `family` INR 236000,
`early_bird` INR 2000. These identify member/member/guest respectively.
Unknown plans or unexpected amounts go to review; descriptions and payment method
are not classification inputs. Processing fees are not subtracted from the expected price.

Set `PLAN_POLICIES` as a JSON object in the environment with explicit approved
`validity_days` for each plan. Access starts at the Zoho payment timestamp and ends
that many days later. Do not set this if membership starts on club opening or manual
activation: an activation workflow is then required. Five calendar years are not
always a fixed number of days. No duration has been invented in the defaults.
Without `validity_days`, a verified successful payment is classified member/guest
but its access remains `review` and cannot create bookings.

Each policy requires `user_type` (`member` or `guest`) and `amount` in INR. Optional
`resources` lists eligible resource IDs; omitted/empty means all facilities. Temporary
facility plans must be explicitly added with a price, duration, and facility list.
V1 does not infer a separately selected booking date from payment metadata.
Changing price/validity policies requires a full sync to revalidate stored payments.

Family membership activates only the purchasing account. Family invitations and
additional beneficiaries require a later explicit linking workflow.

## Endpoints

`POST /auth/signup` and `POST /auth/login` both require
`Authorization: Bearer <Clerk session token>`, with no request body. They are
idempotent user synchronization endpoints, not password/OTP endpoints. Complete
Clerk's sign-in/sign-up flow first. They fetch the current verified contacts from Clerk,
match locally imported records and refresh up to ten candidate payments when due
(default five minutes). Bulk import belongs to the worker, not the login request.

Example response:

```json
{
  "user_id": "user_example",
  "user_type": "member",
  "access_status": "active",
  "payment_verification": "verified",
  "purchases": [{"plan":"individual","valid_from":"2026-10-27T00:00:00Z","valid_until":"2026-11-26T00:00:00Z"}]
}
```

`user_type` is member, guest or null. Access is active, pending, inactive or review.
Verification is verified, pending, not_paid or review. Cancelled/failed/pending payments
grant nothing. Any refund or dispute holds that purchase; another valid purchase can
still grant access. Active membership wins over active guest purchases.

Contact conflicts, multiple successful payments sharing one reference, changed
payment ownership or another claimant hold the payment for review. Ownership
conflicts are sticky and are never cleared by a Zoho refresh. Resolving these requires
an audited operator action; V1 exposes no public claim-transfer endpoint. Phone
normalization assumes +91 for unprefixed ten-digit numbers. Matching is exact after
normalization; payment IDs and references alone cannot claim a purchase.

The webhook validates HMAC-SHA256 over `timestamp.raw_body`, checks a five-minute
replay window, live mode and account ID, then durably queues the payment ID by unique
event ID. It responds 202 without calling Zoho. No full webhook payload or UPI/bank
information is retained. Worker fetches the current authoritative payment, so delayed
or duplicate events cannot roll status back. Unknown event shapes are ignored;
hourly reconciliation also discovers changes. Limit webhook body to 256 KiB.

Successful payment validation checks plan, reference metadata (`EHC-` prefix),
reference-number consistency when present, INR price, refunds and paid timestamp.
The trusted account-specific Zoho retrieval provides merchant/live isolation. Only
live Zoho credentials/endpoints are supported by this backend; sandbox payments
must never be imported into the live application database.

## Authorization and failure behavior

Creating bookings and checking availability require active paid access in Clerk mode.
The full proposed interval must fit a valid paid period and permitted facilities.
Users can still read/cancel their own existing bookings after access expires.
User identity always comes from the verified token.

A provider timeout leaves verification pending. Previously verified access remains
usable until expiry, with a maximum 24-hour payment-verification age. Beyond that,
new bookings are blocked until successful revalidation. This is the explicit V1 outage
grace period. Clerk profile-fetch failures return 503; no unverified identity is claimed.
Protect login/signup with hosting-level rate limits and use HTTPS.

`AUTH_MODE=development` explicitly enables legacy local HS256 demo tokens and
bypasses paid-booking eligibility. Never use it in production. The test suite sets it
only for existing booking tests; separate tests exercise Clerk verification and access.

Runtime DB permissions now include read/insert/update on app_users, payments,
payment_events and payment_sync_state, in addition to the existing booking tables.

## Verification

`pytest -q` uses the dedicated `_test` PostgreSQL database only. Provider requests
are simulated; tests do not create Clerk users or charge/refund Zoho payments.
Live staging verification with your own credentials remains required before launch.

References: [Clerk session verification](https://clerk.com/docs/guides/sessions/manual-jwt-verification),
[Zoho payment APIs](https://www.zoho.com/in/payments/api/v1/payments/),
[Zoho webhook signatures](https://www.zoho.com/in/payments/developerdocs/webhooks/verification/).

## Individual member accounts

In Clerk Organization settings, keep membership optional (`force_organization_selection=false`). This app uses individual accounts. Requiring organization membership leaves native sessions pending on `choose-organization`. After changing this setting, sign in again to replace a pending session.
