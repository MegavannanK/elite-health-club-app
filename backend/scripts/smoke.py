"""Exercise a running API. Creates a future court booking, then cancels it."""
import os
import sys
from datetime import datetime, timedelta
from uuid import uuid4
from zoneinfo import ZoneInfo

import httpx2 as httpx

token = os.environ.get("TOKEN")
if not token:
    sys.exit("Set TOKEN first; see README.md")
body = {"resource_id": "outdoor-court", "date": (datetime.now(ZoneInfo("Asia/Kolkata")) + timedelta(days=7)).date().isoformat(), "start_time": "10:00", "duration_unit": "hourly", "duration": 1}
headers = {"Authorization": f"Bearer {token}", "Idempotency-Key": str(uuid4())}
with httpx.Client(base_url=os.environ.get("API_URL", "http://127.0.0.1:8000"), headers=headers, timeout=15) as client:
    assert client.get("/health/ready").status_code == 200
    assert client.get("/v1/resources").status_code == 200
    first = client.post("/v1/bookings", json=body)
    assert first.status_code == 201, first.text
    booking_id = first.json()["id"]
    try:
        retry = client.post("/v1/bookings", json=body)
        assert retry.status_code == 200 and retry.json()["id"] == booking_id
        conflict = client.post("/v1/bookings", json=body, headers={"Idempotency-Key": str(uuid4())})
        assert conflict.status_code == 409, conflict.text
        assert client.get(f"/v1/bookings/{booking_id}").status_code == 200
    finally:
        cancellation = client.post(f"/v1/bookings/{booking_id}/cancel")
        assert cancellation.status_code == 200, cancellation.text
print("PASS: health, resources, create, safe retry, overlap conflict, read, cancellation")
