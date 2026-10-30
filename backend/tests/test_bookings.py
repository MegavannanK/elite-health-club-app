from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from threading import Barrier

import psycopg
import pytest


def book(client, headers, body, **changes):
    return client.post("/v1/bookings", headers=headers, json=body | changes)


def test_create_retry_duplicate_and_key_mismatch(client, headers, body):
    first = book(client, headers, body)
    assert first.status_code == 201, first.text
    assert first.json()["starts_at"].endswith("04:30:00Z")
    assert first.json()["ends_at"].endswith("06:30:00Z")
    retry = book(client, headers, body)
    assert retry.status_code == 200
    assert retry.json() == first.json()
    assert book(client, headers | {"Idempotency-Key": "new"}, body).status_code == 409
    assert book(client, headers, body, duration=3).status_code == 409
    assert len(client.get("/v1/bookings", headers=headers).json()) == 1


@pytest.mark.parametrize("start,duration,expected", [("09:00", 2, 409), ("10:00", 1, 409), ("11:00", 2, 409), ("09:00", 4, 409), ("12:00", 1, 201), ("09:00", 1, 201)])
def test_overlap_and_adjacent_boundaries(client, headers, body, start, duration, expected):
    assert book(client, headers, body).status_code == 201
    result = book(client, headers | {"Idempotency-Key": "second"}, body, start_time=start, duration=duration)
    assert result.status_code == expected, result.text


def test_availability_and_cancel_releases_slot(client, headers, body):
    assert client.post("/v1/availability", headers=headers, json=body).json()["available"]
    booking = book(client, headers, body).json()
    assert not client.post("/v1/availability", headers=headers, json=body).json()["available"]
    path = f"/v1/bookings/{booking['id']}/cancel"
    cancelled = client.post(path, headers=headers)
    assert cancelled.status_code == 200
    assert cancelled.json()["status"] == "cancelled"
    assert client.post(path, headers=headers).json() == cancelled.json()
    # A retry after cancellation must never resurrect the booking.
    assert book(client, headers, body).json()["status"] == "cancelled"
    assert client.post("/v1/availability", headers=headers, json=body).json()["available"]
    assert book(client, headers | {"Idempotency-Key": "replacement"}, body).status_code == 201


def test_daily_and_hourly_share_same_collision_rule(client, headers, body):
    daily = {k: v for k, v in body.items() if k != "start_time"} | {"duration_unit": "daily", "duration": 1}
    result = book(client, headers, daily)
    assert result.status_code == 201
    assert result.json()["starts_at"].endswith("18:30:00Z")
    assert book(client, headers | {"Idempotency-Key": "hourly"}, body).status_code == 409
    assert book(client, headers | {"Idempotency-Key": "suite"}, daily, resource_id="suite-1").status_code == 201
    assert book(client, headers | {"Idempotency-Key": "suite2"}, daily, resource_id="suite-2").status_code == 201


@pytest.mark.parametrize("changes", [
    {"duration": 0}, {"duration": -1}, {"duration": 25}, {"duration": 1.25}, {"duration": True}, {"duration": "2"},
    {"start_time": None}, {"start_time": "25:00"}, {"start_time": "10:00:01"}, {"start_time": "10:00+05:30"},
    {"duration_unit": "weekly"}, {"duration_unit": "daily"}, {"date": "2026-02-30"},
    {"date": "2020-01-01"}, {"user_id": "another-member"}, {"resource_id": "../court"},
    {"date": "9999-12-31", "duration_unit": "daily", "start_time": None},
    {"date": "0001-01-01", "duration_unit": "daily", "start_time": None},
    {"date": (datetime.now(timezone.utc) + timedelta(days=800)).date().isoformat()},
])
def test_invalid_requests(client, headers, body, changes):
    assert book(client, headers, body, **changes).status_code == 422


def test_resource_missing_inactive_and_unsupported_unit(client, headers, body, database_url):
    assert book(client, headers, body, resource_id="missing").status_code == 404
    assert book(client, headers, body, resource_id="suite-1").status_code == 422
    with psycopg.connect(database_url) as connection:
        connection.execute("UPDATE resources SET active=false WHERE id='outdoor-court'")
    assert book(client, headers, body).status_code == 409


def test_auth_and_ownership(client, headers, body, token):
    assert client.get("/v1/resources").status_code == 401
    assert book(client, {"Authorization": "Bearer invalid", "Idempotency-Key": "x"}, body).status_code == 401
    for bad_token in [token(exp=0), token(aud="wrong"), token(iss="wrong"), token(user="")]:
        assert client.get("/v1/resources", headers={"Authorization": f"Bearer {bad_token}"}).status_code == 401
    result = book(client, headers, body).json()
    other = headers | {"Authorization": f"Bearer {token('member-2')}"}
    assert client.get(f"/v1/bookings/{result['id']}", headers=other).status_code == 404
    assert client.post(f"/v1/bookings/{result['id']}/cancel", headers=other).status_code == 404
    assert client.get("/v1/bookings", headers=other).json() == []
    assert client.get(f"/v1/bookings/{result['id']}", headers=headers).status_code == 200


def test_missing_key_pagination_and_health(client, headers, body):
    assert book(client, {"Authorization": headers["Authorization"]}, body).status_code == 422
    assert book(client, headers | {"Idempotency-Key": " "}, body).status_code == 422
    assert client.get("/v1/bookings?limit=101", headers=headers).status_code == 422
    assert client.get("/health/live").status_code == 200
    assert client.get("/health/ready").status_code == 200
    assert len(client.get("/v1/resources", headers=headers).json()) == 13


def test_many_users_racing_for_one_slot(client, headers, body, token, database_url):
    barrier = Barrier(8)
    def attempt(index):
        barrier.wait(timeout=10)
        return book(client, headers | {"Authorization": f"Bearer {token(f'member-{index}')}"}, body)
    with ThreadPoolExecutor(max_workers=8) as executor:
        responses = list(executor.map(attempt, range(8)))
    assert sorted(r.status_code for r in responses) == [201] + [409] * 7, [(r.status_code, r.text) for r in responses]
    with psycopg.connect(database_url) as connection:
        assert connection.execute("SELECT count(*) FROM bookings").fetchone()[0] == 1


def test_simultaneous_identical_retries(client, headers, body):
    barrier = Barrier(6)
    def attempt(_):
        barrier.wait(timeout=10)
        return book(client, headers, body)
    with ThreadPoolExecutor(max_workers=6) as executor:
        responses = list(executor.map(attempt, range(6)))
    assert sorted(r.status_code for r in responses) == [200] * 5 + [201]
    assert len({r.json()["id"] for r in responses}) == 1


def test_cross_midnight_collision(client, headers, body):
    assert book(client, headers, body, start_time="23:00", duration=2).status_code == 201
    tomorrow = (datetime.fromisoformat(body["date"]) + timedelta(days=1)).date().isoformat()
    assert book(client, headers | {"Idempotency-Key": "tomorrow"}, body, date=tomorrow, start_time="00:00", duration=1).status_code == 409


def test_cannot_cancel_started_booking(client, headers, body, database_url):
    result = book(client, headers, body).json()
    with psycopg.connect(database_url) as connection:
        connection.execute("UPDATE bookings SET starts_at=now()-interval '1 hour' WHERE id=%s", (result["id"],))
    assert client.post(f"/v1/bookings/{result['id']}/cancel", headers=headers).status_code == 409
    # Replays remain safe after the original start time passes.
    assert book(client, headers, body).status_code == 200


def test_same_key_different_users_independent_resources(client, headers, body, token):
    daily = {k: v for k, v in body.items() if k != "start_time"} | {"resource_id": "suite-1", "duration_unit": "daily", "duration": 30}
    assert book(client, headers, daily).status_code == 201
    other = headers | {"Authorization": f"Bearer {token('member-2')}"}
    assert book(client, other, daily, resource_id="suite-2").status_code == 201


def test_database_constraint_protects_direct_writes(client, headers, body, database_url):
    from uuid import uuid4
    original = book(client, headers, body).json()
    with pytest.raises(psycopg.errors.ExclusionViolation):
        with psycopg.connect(database_url) as connection:
            connection.execute("""INSERT INTO bookings
                (id,resource_id,user_id,starts_at,ends_at,duration_unit,duration,idempotency_key,request_payload)
                VALUES (%s,%s,'direct-writer',%s,%s,'hourly',2,'direct-key','{}')""",
                (uuid4(), original["resource_id"], original["starts_at"], original["ends_at"]))


def test_daily_adjacent_checkout_and_duration_limit(client, headers, body):
    daily = {k: v for k, v in body.items() if k != "start_time"} | {"resource_id": "suite-1", "duration_unit": "daily", "duration": 1}
    assert book(client, headers, daily).status_code == 201
    following = (datetime.fromisoformat(daily["date"]) + timedelta(days=1)).date().isoformat()
    assert book(client, headers | {"Idempotency-Key": "next-day"}, daily, date=following).status_code == 201
    assert book(client, headers | {"Idempotency-Key": "too-long"}, daily, duration=31).status_code == 422


@pytest.mark.parametrize("start", ["10:01", "10:15", "10:29", "10:31", "10:59", "10:30:00.001"])
def test_half_hour_start_required(client, headers, body, start):
    for route in ("/v1/availability", "/v1/bookings"):
        assert client.post(route, headers=headers, json=body | {"start_time": start}).status_code == 422


def test_half_hour_duration_and_boundaries(client, headers, body):
    first = book(client, headers, body, start_time="10:30", duration=0.5)
    assert first.status_code == 201, first.text
    assert first.json()["duration"] == 0.5
    assert first.json()["starts_at"].endswith("05:00:00Z")
    assert first.json()["ends_at"].endswith("05:30:00Z")
    assert book(client, headers, body, start_time="10:30", duration=0.5).status_code == 200
    assert book(client, headers | {"Idempotency-Key": "overlap"}, body, duration=1.5).status_code == 409
    assert book(client, headers | {"Idempotency-Key": "adjacent"}, body, start_time="11:00", duration=0.5).status_code == 201


def test_facility_catalog_and_independence(client, headers, body, database_url):
    from app.manage import seed
    seed(database_url)
    catalog = {r["id"]: r for r in client.get("/v1/resources", headers=headers).json()}
    assert len(catalog) == 13
    for facility in ["swimming-pool", "sauna", "steam-bath", "basketball", "badminton", "tennis"]:
        assert catalog[facility]["preferred_unit"] == "hourly"
        assert catalog[facility]["hourly_start_step_minutes"] == 30
        key = headers | {"Idempotency-Key": facility}
        assert book(client, key, body, resource_id=facility, duration=0.5).status_code == 201
        assert book(client, key | {"Idempotency-Key": facility + "-duplicate"}, body, resource_id=facility).status_code == 409
    for facility in ["suite-1", "suite-2", "suite-3", "conference-hall", "meeting-room", "workspaces"]:
        assert catalog[facility]["allowed_units"] == ["daily"]
        assert catalog[facility]["preferred_unit"] == "daily"
        daily = body | {"resource_id": facility, "duration_unit": "daily", "start_time": None}
        key = headers | {"Idempotency-Key": facility}
        assert book(client, key, daily, duration=1.5).status_code == 422
        assert book(client, key, daily, duration=1).status_code == 201
        assert not client.post("/v1/availability", headers=headers, json=daily).json()["available"]
        assert book(client, key | {"Idempotency-Key": facility + "-duplicate"}, daily).status_code == 409


def test_reschedule_preserves_booking_and_conflict_rolls_back(client, headers, body):
    original = book(client, headers, body).json()
    path = f"/v1/bookings/{original['id']}/reschedule"
    moved = client.post(path, headers=headers, json=body | {"start_time": "11:00"})
    assert moved.status_code == 200, moved.text
    assert moved.json()['id'] == original['id']
    assert moved.json()['starts_at'].endswith('05:30:00Z')
    assert client.post(path, headers=headers, json=body | {"start_time": "11:00"}).json() == moved.json()
    assert book(client, headers | {'Idempotency-Key': 'another'}, body, start_time='14:00').status_code == 201
    conflict = client.post(path, headers=headers, json=body | {'start_time': '14:00'})
    assert conflict.status_code == 409
    assert client.get(f"/v1/bookings/{original['id']}", headers=headers).json() == moved.json()


def test_reschedule_ownership_and_cancelled(client, headers, body, token):
    original = book(client, headers, body).json()
    path = f"/v1/bookings/{original['id']}/reschedule"
    other = headers | {'Authorization': f"Bearer {token('member-2')}"}
    assert client.post(path, headers=other, json=body).status_code == 404
    assert client.post(path, headers=headers, json=body | {'resource_id': 'tennis'}).status_code == 422
    client.post(f"/v1/bookings/{original['id']}/cancel", headers=headers)
    assert client.post(path, headers=headers, json=body).status_code == 409
