import contextlib
import logging
import os
import random
import threading
import time

import psycopg
import pyroscope
from flask import Flask, jsonify
from prometheus_client import Counter as PromCounter, Histogram as PromHistogram, CONTENT_TYPE_LATEST, generate_latest

from opentelemetry import metrics, trace
from opentelemetry._logs import set_logger_provider
from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace import Status, StatusCode

SERVICE_NAME = os.getenv("OTEL_SERVICE_NAME", "backend")
SERVICE_VERSION = os.getenv("SERVICE_VERSION", "dev")
OTLP_ENDPOINT = os.getenv(
    "OTEL_EXPORTER_OTLP_ENDPOINT",
    "lgtm.observability.svc.cluster.local:4317",
)
PYROSCOPE_ENDPOINT = os.getenv(
    "PYROSCOPE_SERVER_ADDRESS",
    "http://lgtm.observability.svc.cluster.local:4040",
)

DB_HOST = os.getenv("DB_HOST", "")
DB_PORT = int(os.getenv("DB_PORT", "5432"))
DB_NAME = os.getenv("DB_NAME", "observability")
DB_USER = os.getenv("DB_USER", "")
DB_PASSWORD = os.getenv("DB_PASSWORD", "")

K8S_NAMESPACE = os.getenv("K8S_NAMESPACE", "")
K8S_POD_NAME = os.getenv("K8S_POD_NAME", "")
K8S_POD_UID = os.getenv("K8S_POD_UID", "")
K8S_NODE_NAME = os.getenv("K8S_NODE_NAME", "")

resource_attributes = {
    "service.name": SERVICE_NAME,
    "service.namespace": "day3",
    "service.version": SERVICE_VERSION,
    "deployment.environment.name": "dev",
}

for key, value in {
    "k8s.namespace.name": K8S_NAMESPACE,
    "k8s.pod.name": K8S_POD_NAME,
    "k8s.pod.uid": K8S_POD_UID,
    "k8s.node.name": K8S_NODE_NAME,
}.items():
    if value:
        resource_attributes[key] = value

resource = Resource.create(resource_attributes)

# ---- Traces ----
tracer_provider = TracerProvider(resource=resource)
tracer_provider.add_span_processor(
    BatchSpanProcessor(OTLPSpanExporter(endpoint=OTLP_ENDPOINT, insecure=True))
)
trace.set_tracer_provider(tracer_provider)
tracer = trace.get_tracer(__name__)

# ---- Metrics (OTLP) ----
metric_reader = PeriodicExportingMetricReader(
    OTLPMetricExporter(endpoint=OTLP_ENDPOINT, insecure=True),
    export_interval_millis=5000,
)
meter_provider = MeterProvider(resource=resource, metric_readers=[metric_reader])
metrics.set_meter_provider(meter_provider)
meter = metrics.get_meter(__name__)
otel_requests = meter.create_counter("backend.requests", unit="1")
otel_latency = meter.create_histogram("backend.request.duration", unit="s")
otel_db_operations = meter.create_counter("backend.db.operations", unit="1")
otel_db_latency = meter.create_histogram("backend.db.operation.duration", unit="s")

# ---- Logs (OTLP) ----
logger_provider = LoggerProvider(resource=resource)
logger_provider.add_log_record_processor(
    BatchLogRecordProcessor(OTLPLogExporter(endpoint=OTLP_ENDPOINT, insecure=True))
)
set_logger_provider(logger_provider)
logging.basicConfig(level=logging.INFO)
root_logger = logging.getLogger()
root_logger.addHandler(LoggingHandler(level=logging.INFO, logger_provider=logger_provider))
logger = logging.getLogger("backend")

# ---- Profiles (Pyroscope) ----
PROFILING_ENABLED = False
try:
    pyroscope.configure(
        application_name="day3.backend",
        server_address=PYROSCOPE_ENDPOINT,
        tags={
            "service": SERVICE_NAME,
            "version": SERVICE_VERSION,
            "environment": "dev",
            "namespace": K8S_NAMESPACE or "unknown",
            "pod": K8S_POD_NAME or "unknown",
            "node": K8S_NODE_NAME or "unknown",
        },
        cpu_enabled=True,
        mem_enabled=True,
    )
    PROFILING_ENABLED = True
except Exception as exc:
    logger.warning("profiling disabled error=%s", exc)

# ---- Prometheus-format endpoint for learning/scraping exercises ----
prom_requests = PromCounter(
    "backend_requests_total",
    "Total backend requests",
    ["status"],
)
prom_latency = PromHistogram(
    "backend_request_duration_seconds",
    "Backend request duration in seconds",
)
prom_db_operations = PromCounter(
    "backend_db_operations_total",
    "Total PostgreSQL operations",
    ["operation", "status"],
)
prom_db_latency = PromHistogram(
    "backend_db_operation_duration_seconds",
    "PostgreSQL operation duration in seconds",
    ["operation"],
)

app = Flask(__name__)
FlaskInstrumentor().instrument_app(app)

_db_initialized = False
_db_init_lock = threading.Lock()


def profile_tag(tags):
    if PROFILING_ENABLED:
        return pyroscope.tag_wrapper(tags)
    return contextlib.nullcontext()


def db_connection():
    if not all([DB_HOST, DB_USER, DB_PASSWORD]):
        raise RuntimeError("database configuration is incomplete")

    return psycopg.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
        connect_timeout=5,
        sslmode="require",
        autocommit=True,
    )


def record_db_metric(operation, duration, success):
    status = "ok" if success else "error"
    attributes = {
        "db.system.name": "postgresql",
        "db.operation.name": operation,
        "db.operation.status": status,
    }
    otel_db_operations.add(1, attributes)
    otel_db_latency.record(duration, attributes)
    prom_db_operations.labels(operation=operation, status=status).inc()
    prom_db_latency.labels(operation=operation).observe(duration)


def initialize_database():
    global _db_initialized

    if _db_initialized:
        return

    with _db_init_lock:
        if _db_initialized:
            return

        started = time.perf_counter()
        success = False

        with tracer.start_as_current_span("postgres.schema.init") as span:
            span.set_attribute("db.system.name", "postgresql")
            span.set_attribute("db.namespace", DB_NAME)
            span.set_attribute("server.address", DB_HOST)
            span.set_attribute("server.port", DB_PORT)

            try:
                with db_connection() as conn:
                    with conn.cursor() as cur:
                        cur.execute(
                            """
                            CREATE TABLE IF NOT EXISTS observability_events (
                                id BIGSERIAL PRIMARY KEY,
                                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                                service_version TEXT NOT NULL,
                                synthetic_delay_ms INTEGER NOT NULL,
                                request_status INTEGER NOT NULL
                            )
                            """
                        )
                success = True
                _db_initialized = True
                logger.info("database schema ready host=%s db=%s", DB_HOST, DB_NAME)
            except Exception as exc:
                span.record_exception(exc)
                span.set_status(Status(StatusCode.ERROR, str(exc)))
                logger.exception("database schema initialization failed host=%s db=%s", DB_HOST, DB_NAME)
                raise
            finally:
                duration = time.perf_counter() - started
                record_db_metric("schema_init", duration, success)


def database_round_trip(delay_seconds, request_status):
    initialize_database()

    inserted_id = None
    event_count = 0

    started = time.perf_counter()
    success = False
    with profile_tag({"db_operation": "insert"}):
        with tracer.start_as_current_span("postgres.insert") as span:
            span.set_attribute("db.system.name", "postgresql")
            span.set_attribute("db.namespace", DB_NAME)
            span.set_attribute("db.operation.name", "INSERT")
            span.set_attribute("server.address", DB_HOST)
            span.set_attribute("server.port", DB_PORT)
            try:
                with db_connection() as conn:
                    with conn.cursor() as cur:
                        cur.execute(
                            """
                            INSERT INTO observability_events
                                (service_version, synthetic_delay_ms, request_status)
                            VALUES (%s, %s, %s)
                            RETURNING id
                            """,
                            (
                                SERVICE_VERSION,
                                int(delay_seconds * 1000),
                                request_status,
                            ),
                        )
                        inserted_id = cur.fetchone()[0]
                success = True
                logger.info("db write ok event_id=%s", inserted_id)
            except Exception as exc:
                span.record_exception(exc)
                span.set_status(Status(StatusCode.ERROR, str(exc)))
                logger.exception("db write failed")
                raise
            finally:
                duration = time.perf_counter() - started
                record_db_metric("insert", duration, success)

    started = time.perf_counter()
    success = False
    with profile_tag({"db_operation": "select"}):
        with tracer.start_as_current_span("postgres.select") as span:
            span.set_attribute("db.system.name", "postgresql")
            span.set_attribute("db.namespace", DB_NAME)
            span.set_attribute("db.operation.name", "SELECT")
            span.set_attribute("server.address", DB_HOST)
            span.set_attribute("server.port", DB_PORT)
            try:
                with db_connection() as conn:
                    with conn.cursor() as cur:
                        cur.execute("SELECT COUNT(*) FROM observability_events")
                        event_count = cur.fetchone()[0]
                success = True
                logger.info("db read ok event_count=%s", event_count)
            except Exception as exc:
                span.record_exception(exc)
                span.set_status(Status(StatusCode.ERROR, str(exc)))
                logger.exception("db read failed")
                raise
            finally:
                duration = time.perf_counter() - started
                record_db_metric("select", duration, success)

    return inserted_id, event_count


@app.get("/health")
def health():
    return {
        "status": "healthy",
        "version": SERVICE_VERSION,
        "database_configured": bool(DB_HOST),
        "profiling_enabled": PROFILING_ENABLED,
    }


@app.get("/metrics")
def prometheus_metrics():
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}


@app.get("/db")
def database_status():
    started = time.perf_counter()
    try:
        initialize_database()
        with db_connection() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT COUNT(*), MAX(created_at) FROM observability_events"
                )
                count, latest = cur.fetchone()
        duration = time.perf_counter() - started
        return {
            "status": "ok",
            "events": count,
            "latest": latest.isoformat() if latest else None,
            "duration_ms": round(duration * 1000, 2),
        }
    except Exception as exc:
        logger.exception("database status failed")
        return jsonify({"status": "error", "error": type(exc).__name__}), 503


@app.get("/work")
def work():
    start = time.perf_counter()
    delay = random.choice([0.05, 0.08, 0.10, 0.15, 0.60])
    status = 200

    with profile_tag({"workload": "compute"}):
        with tracer.start_as_current_span("backend.compute") as span:
            span.set_attribute("demo.delay_seconds", delay)
            span.set_attribute("service.version", SERVICE_VERSION)
            time.sleep(delay)

            if random.random() < 0.10:
                status = 500
                span.set_attribute("demo.failed", True)

    try:
        event_id, event_count = database_round_trip(delay, status)
    except Exception as exc:
        duration = time.perf_counter() - start
        attributes = {
            "http.response.status_code": 503,
            "service.version": SERVICE_VERSION,
        }
        otel_requests.add(1, attributes)
        otel_latency.record(duration, attributes)
        prom_requests.labels(status="503").inc()
        prom_latency.observe(duration)
        logger.error("backend request failed because database is unavailable error=%s", type(exc).__name__)
        return jsonify({"status": "database_error", "version": SERVICE_VERSION}), 503

    duration = time.perf_counter() - start
    attributes = {
        "http.response.status_code": status,
        "service.version": SERVICE_VERSION,
    }
    otel_requests.add(1, attributes)
    otel_latency.record(duration, attributes)
    prom_requests.labels(status=str(status)).inc()
    prom_latency.observe(duration)

    if status == 500:
        logger.error(
            "backend request failed delay=%.3f version=%s event_id=%s event_count=%s",
            delay,
            SERVICE_VERSION,
            event_id,
            event_count,
        )
        return jsonify(
            {
                "status": "failed",
                "delay": delay,
                "version": SERVICE_VERSION,
                "event_id": event_id,
                "event_count": event_count,
            }
        ), 500

    logger.info(
        "backend request ok delay=%.3f version=%s event_id=%s event_count=%s",
        delay,
        SERVICE_VERSION,
        event_id,
        event_count,
    )
    return jsonify(
        {
            "status": "ok",
            "delay": delay,
            "version": SERVICE_VERSION,
            "event_id": event_id,
            "event_count": event_count,
        }
    )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
