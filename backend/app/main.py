from contextlib import asynccontextmanager
from datetime import datetime, time, timedelta, timezone
from typing import Annotated
from uuid import UUID, uuid4
from zoneinfo import ZoneInfo

import psycopg
from fastapi import FastAPI, Header, HTTPException, Query, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb
from psycopg_pool import ConnectionPool

from app.auth import User
from app.membership import PaidUser, authorize_interval
from app.payment_routes import router as payment_router
from app.config import settings
from app.schemas import AvailabilityOut, BookingOut, BookingRequest, ResourceOut


@asynccontextmanager
async def lifespan(app: FastAPI):
    with ConnectionPool(settings().database_url, min_size=1, max_size=10, timeout=5,
                        kwargs={"row_factory": dict_row, "options": "-c statement_timeout=10000 -c lock_timeout=5000"}) as pool:
        pool.wait(timeout=15)
        app.state.pool = pool
        yield


app = FastAPI(title="Elite Health Club Booking API", version="1.0.0", lifespan=lifespan)
app.include_router(payment_router)
app.add_middleware(CORSMiddleware, allow_origins=settings().cors_origins,
                   allow_methods=["GET", "POST"], allow_headers=["Authorization", "Content-Type", "Idempotency-Key"])


@app.exception_handler(psycopg.OperationalError)
@app.exception_handler(psycopg.errors.QueryCanceled)
@app.exception_handler(psycopg.errors.LockNotAvailable)
def database_unavailable(request: Request, error: Exception):
    return JSONResponse(status_code=503, content={"detail": "Database busy or unavailable; retry shortly with the same Idempotency-Key"}, headers={"Retry-After": "2"})


def resource(connection, resource_id: str):
    row = connection.execute("SELECT * FROM resources WHERE id = %s FOR SHARE", (resource_id,)).fetchone()
    if row is None:
        raise HTTPException(404, "Resource not found")
    if not row["active"]:
        raise HTTPException(409, "Resource is unavailable")
    return row


def interval(body: BookingRequest, selected: dict):
    if body.duration_unit.value not in selected["allowed_units"]:
        raise HTTPException(422, "This resource does not support that duration unit")
    zone = ZoneInfo(selected["timezone"])
    now = datetime.now(timezone.utc)
    # Reject extreme dates before timezone arithmetic (year 1 can underflow UTC).
    if body.date < now.astimezone(zone).date():
        raise HTTPException(422, "Booking must start in the future")
    if body.date > (now + timedelta(days=settings().max_advance_days)).astimezone(zone).date():
        raise HTTPException(422, "Booking start exceeds the advance booking limit")
    local = datetime.combine(body.date, body.start_time or time.min)
    start = local.replace(tzinfo=zone)
    # Reject local times that are missing or ambiguous across daylight-saving changes.
    if start.astimezone(timezone.utc).astimezone(zone).replace(tzinfo=None) != local or start.utcoffset() != local.replace(tzinfo=zone, fold=1).utcoffset():
        raise HTTPException(422, "Ambiguous or nonexistent local start time")
    if start <= now:
        raise HTTPException(422, "Booking must start in the future")
    if start > now + timedelta(days=settings().max_advance_days):
        raise HTTPException(422, "Booking start exceeds the advance booking limit")
    if body.duration_unit == "daily":
        end = start + timedelta(days=int(body.duration))
    else:
        end = start.astimezone(timezone.utc) + timedelta(hours=body.duration)
    start, end = start.astimezone(timezone.utc), end.astimezone(timezone.utc)
    return start, end


@app.get("/health/live", tags=["Health"])
def live():
    return {"status": "ok"}


@app.get("/health/ready", tags=["Health"])
def ready(request: Request):
    with request.app.state.pool.connection() as connection:
        connection.execute("SELECT 1 FROM resources LIMIT 1")
    return {"status": "ready"}


@app.get("/v1/resources", response_model=list[ResourceOut], tags=["Resources"])
def resources(request: Request, user: User):
    with request.app.state.pool.connection() as connection:
        return connection.execute("SELECT * FROM resources WHERE active ORDER BY id").fetchall()


@app.post("/v1/availability/slots", tags=["Bookings"])
def slot_availability(body: BookingRequest, request: Request, user: PaidUser):
    """Return the entire slot map from one consistent occupancy snapshot."""
    with request.app.state.pool.connection() as connection:
        selected = resource(connection, body.resource_id)
        occupied = connection.execute(
            "SELECT starts_at, ends_at FROM bookings WHERE resource_id=%s AND status='confirmed' AND ends_at > %s AND starts_at < %s",
            (body.resource_id,
             datetime.combine(body.date, time.min, ZoneInfo(selected["timezone"])),
             datetime.combine(body.date, time.min, ZoneInfo(selected["timezone"])) + timedelta(days=1, hours=body.duration)),
        ).fetchall()
        slots = []
        for minute in range(0, 1440, 30):
            candidate = body.model_copy(update={"start_time": time(minute // 60, minute % 60)})
            try:
                start, end = interval(candidate, selected)
                authorize_interval(connection, user, body.resource_id, start, end)
                status = "Booked" if any(row["starts_at"] < end and row["ends_at"] > start for row in occupied) else "Available"
            except HTTPException as exc:
                if exc.status_code not in (403, 422):
                    raise
                status = "Unavailable"
            slots.append({"minute": minute, "status": status})
        return {"slots": slots}


@app.post("/v1/availability", response_model=AvailabilityOut, tags=["Bookings"])
def availability(body: BookingRequest, request: Request, user: PaidUser):
    """An availability snapshot; only a successful booking reserves the interval."""
    with request.app.state.pool.connection() as connection:
        start, end = interval(body, resource(connection, body.resource_id))
        authorize_interval(connection, user, body.resource_id, start, end)
        occupied = connection.execute("SELECT 1 FROM bookings WHERE resource_id=%s AND status='confirmed' AND tstzrange(starts_at,ends_at,'[)') && tstzrange(%s,%s,'[)') LIMIT 1", (body.resource_id, start, end)).fetchone()
        return {"resource_id": body.resource_id, "starts_at": start, "ends_at": end, "available": occupied is None}


@app.post("/v1/bookings", response_model=BookingOut, status_code=201, tags=["Bookings"],
          responses={200: {"description": "Existing booking from an identical retry", "model": BookingOut}, 409: {"description": "Overlap or reused key with a different payload"}})
def create_booking(body: BookingRequest, request: Request, response: Response, user: PaidUser,
                   idempotency_key: Annotated[str, Header(min_length=1, max_length=128, pattern=r"^[A-Za-z0-9._:-]+$")]):
    """Reuse the same key and request when retrying. A fresh booking needs a new key."""
    payload = body.model_dump(mode="json")
    try:
        with request.app.state.pool.connection() as connection:
            # Serializes identical retries across processes; DB uniqueness is a backstop.
            connection.execute("SELECT pg_advisory_xact_lock(hashtextextended(%s,0))", (f"{len(user)}:{user}:{idempotency_key}",))
            existing = connection.execute("SELECT * FROM bookings WHERE user_id=%s AND idempotency_key=%s", (user, idempotency_key)).fetchone()
            if existing:
                if existing["request_payload"] != payload:
                    raise HTTPException(409, "Idempotency-Key already used with a different request")
                response.status_code = 200
                return existing
            start, end = interval(body, resource(connection, body.resource_id))
            authorize_interval(connection, user, body.resource_id, start, end)
            return connection.execute("""
                INSERT INTO bookings(id,resource_id,user_id,starts_at,ends_at,duration_unit,duration,idempotency_key,request_payload)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s) RETURNING *
            """, (uuid4(), body.resource_id, user, start, end, body.duration_unit.value, body.duration, idempotency_key, Jsonb(payload))).fetchone()
    except psycopg.errors.ExclusionViolation:
        raise HTTPException(409, "Resource is already booked for part or all of this interval")
    except (psycopg.errors.DeadlockDetected, psycopg.errors.SerializationFailure):
        raise HTTPException(503, "Concurrent booking change; retry with the same Idempotency-Key", headers={"Retry-After": "2"})


@app.get("/v1/bookings", response_model=list[BookingOut], tags=["Bookings"])
def my_bookings(request: Request, user: User, limit: Annotated[int, Query(ge=1, le=100)] = 20,
                offset: Annotated[int, Query(ge=0, le=10000)] = 0):
    with request.app.state.pool.connection() as connection:
        return connection.execute("SELECT * FROM bookings WHERE user_id=%s ORDER BY created_at DESC,id DESC LIMIT %s OFFSET %s", (user, limit, offset)).fetchall()


@app.get("/v1/bookings/{booking_id}", response_model=BookingOut, tags=["Bookings"])
def get_booking(booking_id: UUID, request: Request, user: User):
    with request.app.state.pool.connection() as connection:
        row = connection.execute("SELECT * FROM bookings WHERE id=%s AND user_id=%s", (booking_id, user)).fetchone()
        if row is None:
            raise HTTPException(404, "Booking not found")
        return row


@app.post("/v1/bookings/{booking_id}/cancel", response_model=BookingOut, tags=["Bookings"])
def cancel_booking(booking_id: UUID, request: Request, user: User):
    with request.app.state.pool.connection() as connection:
        row = connection.execute("SELECT * FROM bookings WHERE id=%s AND user_id=%s FOR UPDATE", (booking_id, user)).fetchone()
        if row is None:
            raise HTTPException(404, "Booking not found")
        if row["status"] == "cancelled":
            return row
        if row["starts_at"] <= datetime.now(timezone.utc):
            raise HTTPException(409, "A started booking cannot be cancelled")
        return connection.execute("UPDATE bookings SET status='cancelled', cancelled_at=now() WHERE id=%s RETURNING *", (booking_id,)).fetchone()


@app.post("/v1/bookings/{booking_id}/reschedule", response_model=BookingOut, tags=["Bookings"])
def reschedule_booking(booking_id: UUID, body: BookingRequest, request: Request, user: PaidUser):
    """Move an upcoming reservation atomically; conflicts preserve its original time."""
    try:
        with request.app.state.pool.connection() as connection:
            row = connection.execute("SELECT * FROM bookings WHERE id=%s AND user_id=%s FOR UPDATE", (booking_id, user)).fetchone()
            if row is None:
                raise HTTPException(404, "Booking not found")
            if row["status"] != "confirmed" or row["starts_at"] <= datetime.now(timezone.utc):
                raise HTTPException(409, "Only upcoming confirmed bookings can be rescheduled")
            if body.resource_id != row["resource_id"]:
                raise HTTPException(422, "Rescheduling must keep the same facility")
            start, end = interval(body, resource(connection, body.resource_id))
            authorize_interval(connection, user, body.resource_id, start, end)
            return connection.execute("""UPDATE bookings
                SET starts_at=%s, ends_at=%s, duration_unit=%s, duration=%s
                WHERE id=%s RETURNING *""",
                (start, end, body.duration_unit.value, body.duration, booking_id)).fetchone()
    except psycopg.errors.ExclusionViolation:
        raise HTTPException(409, "That time is unavailable. Your original booking is unchanged.")
    except (psycopg.errors.DeadlockDetected, psycopg.errors.SerializationFailure):
        raise HTTPException(503, "Concurrent booking change; check My bookings and try again", headers={"Retry-After": "2"})
