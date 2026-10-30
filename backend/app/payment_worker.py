"""Run one pass from a scheduler; failed work remains durable for the next pass."""
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

from app.config import settings
from app.membership import projection, refresh_payment
from app.providers import ProviderUnavailable, zoho


def project_owner(pool, payment_id):
    with pool.connection() as connection:
        row = connection.execute('SELECT user_id FROM payments WHERE payment_id=%s', (payment_id,)).fetchone()
        if row and row['user_id']:
            projection(connection, row['user_id'])


def process_events(pool):
    processed = 0
    with pool.connection() as connection:
        ids = connection.execute("SELECT event_id FROM payment_events WHERE processed_at IS NULL ORDER BY received_at,event_id LIMIT 100").fetchall()
    for selected in ids:
        try:
            with pool.connection() as connection:
                event = connection.execute("SELECT * FROM payment_events WHERE event_id=%s AND processed_at IS NULL FOR UPDATE SKIP LOCKED", (selected['event_id'],)).fetchone()
                if not event:
                    continue
                refresh_payment(connection, event['payment_id'])
                connection.execute('UPDATE payment_events SET processed_at=now(),attempts=attempts+1 WHERE event_id=%s', (event['event_id'],))
            project_owner(pool, event['payment_id'])
            processed += 1
        except ProviderUnavailable:
            with pool.connection() as connection:
                connection.execute('UPDATE payment_events SET attempts=attempts+1 WHERE event_id=%s', (selected['event_id'],))
    return processed


def reconcile(pool):
    # Only mark the full sync complete after every page/detail succeeds.
    count = 0
    for page in zoho.pages():
        for payment in page:
            with pool.connection() as connection:
                refresh_payment(connection, str(payment['payment_id']))
            project_owner(pool, str(payment['payment_id']))
            count += 1
    with pool.connection() as connection:
        connection.execute('''INSERT INTO payment_sync_state(id,completed_at) VALUES(1,now())
            ON CONFLICT(id) DO UPDATE SET completed_at=excluded.completed_at''')
    return count


def run(command):
    with ConnectionPool(settings().database_url, kwargs={'row_factory': dict_row}) as pool:
        count = reconcile(pool) if command == 'sync-payments' else process_events(pool)
        with pool.connection() as connection:
            for user in connection.execute('SELECT clerk_user_id FROM app_users ORDER BY clerk_user_id').fetchall():
                projection(connection, user['clerk_user_id'])
        print(f'Processed {count} payments/events')


def serve():
    import logging
    import threading
    import time
    logger = logging.getLogger(__name__)
    with ConnectionPool(settings().database_url, kwargs={'row_factory': dict_row}) as pool:
        def import_loop():
            while True:
                try:
                    reconcile(pool)
                except Exception:
                    logger.error('Payment reconciliation failed; retrying in one hour')
                time.sleep(3600)
        threading.Thread(target=import_loop, daemon=True).start()
        while True:
            try:
                process_events(pool)
            except Exception:
                logger.error('Payment event processing failed; retrying')
            time.sleep(5)
