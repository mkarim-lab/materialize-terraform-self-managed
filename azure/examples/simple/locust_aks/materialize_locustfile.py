"""
Direct-to-Materialize point-lookup load test -- bypasses the .NET API entirely and hits
Materialize's Postgres wire protocol directly, to measure the RAW query/index performance in
isolation from API/network/serialization overhead.

Two tasks, both point lookups on an indexed column (see 03-vehicle-contract.sql / 02-peopleorg.sql
for the view + index definitions):
  - customer_lookup: peopleorg.driver WHERE customer_guid = %s (driver_by_guid, peopleorg_serving)
  - order_lookup:    vehicle_contract.contract WHERE order_guid = %s (contract_by_guid, vehicle_serving)

GUID pools (customer_pool_size / order_pool_size) are fetched once per process (not once per
simulated user, and not once per request) via a plain LIMIT query, then each task picks a random
value from the pool -- this keeps the timed lookups themselves free of pool-bootstrap overhead.

Run locally (same env vars as the rest of this repo's .env.azure):
    locust -f materialize_locustfile.py --headless -u 20 -r 5 -t 2m
Run on AKS (closer network path to Materialize): same script, same env vars, just point
MATERIALIZE_HOST at the in-cluster Materialize service/ClusterIP instead of the external LB IP.
"""
from __future__ import annotations

import os
import random
import threading
import time
from dataclasses import dataclass

from gevent import monkey

monkey.patch_all()

import pg8000  # noqa: E402 -- must import after monkey.patch_all()
from locust import User, between, events, task  # noqa: E402


def _env_str(name: str, default: str) -> str:
    return os.getenv(name, "").strip() or default


def _env_int(name: str, default: int) -> int:
    raw = os.getenv(name, "").strip()
    return int(raw) if raw else default


def _env_float(name: str, default: float) -> float:
    raw = os.getenv(name, "").strip()
    return float(raw) if raw else default


@dataclass(frozen=True)
class Settings:
    host: str
    port: int
    database: str
    user: str
    password: str
    sslmode: str
    vehicle_cluster: str
    peopleorg_cluster: str
    customer_pool_size: int
    order_pool_size: int
    min_wait_seconds: float
    max_wait_seconds: float


# Same env var names as the rest of this repo's .env.azure, so this script can be sourced from
# the same file the HammerDB/orchestrator scripts already use -- no separate config needed.
SETTINGS = Settings(
    host=_env_str("MATERIALIZE_HOST", "10.70.150.15"),
    port=_env_int("MATERIALIZE_SQL_PORT", 6875),
    database=_env_str("MATERIALIZE_DB", "materialize"),
    user=_env_str("MATERIALIZE_USER", "sgfleet_user"),
    password=_env_str("MATERIALIZE_USER_PASSWORD", "mz_sgfleeT85323#Dmn"),
    sslmode=_env_str("MATERIALIZE_SSLMODE", "require"),
    vehicle_cluster=_env_str("LOCUST_VEHICLE_CLUSTER", "vehicle_serving"),
    peopleorg_cluster=_env_str("LOCUST_PEOPLEORG_CLUSTER", "peopleorg_serving"),
    customer_pool_size=_env_int("LOCUST_CUSTOMER_POOL_SIZE", 1000),
    order_pool_size=_env_int("LOCUST_ORDER_POOL_SIZE", 2000),
    min_wait_seconds=_env_float("LOCUST_MIN_WAIT_SECONDS", 0.05),
    max_wait_seconds=_env_float("LOCUST_MAX_WAIT_SECONDS", 0.1),
)


def _connect() -> pg8000.dbapi.Connection:
    ssl_context = None
    if SETTINGS.sslmode.lower() != "disable":
        import ssl

        ssl_context = ssl.create_default_context()
        ssl_context.check_hostname = False
        ssl_context.verify_mode = ssl.CERT_NONE
    return pg8000.connect(
        host=SETTINGS.host,
        port=SETTINGS.port,
        database=SETTINGS.database,
        user=SETTINGS.user,
        password=SETTINGS.password,
        ssl_context=ssl_context,
    )


def _record(name: str, start_time: float, row_count: int, exception: BaseException | None = None) -> None:
    events.request.fire(
        request_type="SQL",
        name=name,
        response_time=(time.perf_counter() - start_time) * 1000.0,
        response_length=row_count,
        exception=exception,
    )


# GUID pools are fetched once per process (master/standalone/each distributed worker), not once
# per simulated user -- guarded by a lock so concurrent User.on_start calls in the same process
# don't all race to bootstrap the pool.
_pool_lock = threading.Lock()
_customer_pool: list[str] = []
_order_pool: list[str] = []


def _ensure_pools_loaded() -> None:
    if _customer_pool and _order_pool:
        return
    with _pool_lock:
        if _customer_pool and _order_pool:
            return
        conn = _connect()
        conn.autocommit = True  # SET cluster is rejected inside an active transaction
        try:
            cursor = conn.cursor()
            cursor.execute(f"SET cluster = {SETTINGS.peopleorg_cluster}")
            cursor.execute("SELECT customer_guid FROM peopleorg.driver LIMIT %s", (SETTINGS.customer_pool_size,))
            _customer_pool.extend(str(row[0]) for row in cursor.fetchall())

            cursor.execute(f"SET cluster = {SETTINGS.vehicle_cluster}")
            cursor.execute("SELECT order_guid FROM vehicle_contract.contract LIMIT %s", (SETTINGS.order_pool_size,))
            _order_pool.extend(str(row[0]) for row in cursor.fetchall())
        finally:
            conn.close()

        if not _customer_pool:
            raise RuntimeError("No rows returned from peopleorg.driver -- customer pool is empty.")
        if not _order_pool:
            raise RuntimeError("No rows returned from vehicle_contract.contract -- order pool is empty.")


class MaterializePointLookupUser(User):
    wait_time = between(SETTINGS.min_wait_seconds, SETTINGS.max_wait_seconds)

    def on_start(self) -> None:
        _ensure_pools_loaded()
        # Two connections, each pinned to the cluster its lookups actually run on -- mirrors
        # the .NET API's own pattern of one MaterializeReader per domain (keyed "vehicle" /
        # "peopleorg"), so this test reflects real per-domain connection/cluster routing rather
        # than paying a SET cluster round-trip before every single query.
        self.peopleorg_conn = _connect()
        self.peopleorg_conn.autocommit = True
        self.peopleorg_conn.cursor().execute(f"SET cluster = {SETTINGS.peopleorg_cluster}")

        self.vehicle_conn = _connect()
        self.vehicle_conn.autocommit = True
        self.vehicle_conn.cursor().execute(f"SET cluster = {SETTINGS.vehicle_cluster}")

    def on_stop(self) -> None:
        for conn in (getattr(self, "peopleorg_conn", None), getattr(self, "vehicle_conn", None)):
            if conn is not None:
                conn.close()

    def _execute(self, conn, name: str, sql_text: str, params) -> None:
        start_time = time.perf_counter()
        cursor = conn.cursor()
        try:
            cursor.execute(sql_text, params)
            rows = cursor.fetchall()
            _record(name, start_time, len(rows))
        except Exception as exc:
            _record(name, start_time, 0, exc)
            raise
        finally:
            cursor.close()

    @task(1)
    def customer_lookup(self) -> None:
        # Point lookup by PK, served by driver_by_guid (peopleorg_serving).
        customer_guid = random.choice(_customer_pool)
        self._execute(
            self.peopleorg_conn,
            "customer_lookup",
            """
            SELECT customer_guid, w_id, d_id, c_id,
                   driver_first_name, driver_middle_name, driver_last_name,
                   credit_status, warehouse_name, district_name
            FROM   peopleorg.driver
            WHERE  customer_guid = %s
            """,
            (customer_guid,),
        )

    @task(1)
    def order_lookup(self) -> None:
        # Point lookup by PK, served by contract_by_guid (vehicle_serving).
        order_guid = random.choice(_order_pool)
        self._execute(
            self.vehicle_conn,
            "order_lookup",
            """
            SELECT order_guid, customer_guid, w_id, d_id, o_id, c_id,
                   entry_date, carrier_id, line_count, total_amount, driver_name
            FROM   vehicle_contract.contract
            WHERE  order_guid = %s
            """,
            (order_guid,),
        )
