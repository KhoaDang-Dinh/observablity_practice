import logging
import os
import random
import time

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

SERVICE_NAME = os.getenv("OTEL_SERVICE_NAME", "backend")
SERVICE_VERSION = os.getenv("SERVICE_VERSION", "dev")
OTLP_ENDPOINT = os.getenv(
    "OTEL_EXPORTER_OTLP_ENDPOINT",
    "lgtm.observability.svc.cluster.local:4317",
)

resource = Resource.create(
    {
        "service.name": SERVICE_NAME,
        "service.namespace": "day3",
        "service.version": SERVICE_VERSION,
        "deployment.environment.name": "dev",
    }
)

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

app = Flask(__name__)
FlaskInstrumentor().instrument_app(app)


@app.get("/health")
def health():
    return {"status": "healthy", "version": SERVICE_VERSION}


@app.get("/metrics")
def prometheus_metrics():
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}


@app.get("/work")
def work():
    start = time.perf_counter()
    delay = random.choice([0.05, 0.08, 0.10, 0.15, 0.60])
    status = 200

    with tracer.start_as_current_span("backend.compute") as span:
        span.set_attribute("demo.delay_seconds", delay)
        span.set_attribute("service.version", SERVICE_VERSION)
        time.sleep(delay)

        if random.random() < 0.10:
            status = 500
            span.set_attribute("demo.failed", True)

    duration = time.perf_counter() - start
    attributes = {"http.response.status_code": status, "service.version": SERVICE_VERSION}
    otel_requests.add(1, attributes)
    otel_latency.record(duration, attributes)
    prom_requests.labels(status=str(status)).inc()
    prom_latency.observe(duration)

    if status == 500:
        logger.error("backend request failed delay=%.3f version=%s", delay, SERVICE_VERSION)
        return jsonify({"status": "failed", "delay": delay, "version": SERVICE_VERSION}), 500

    logger.info("backend request ok delay=%.3f version=%s", delay, SERVICE_VERSION)
    return jsonify({"status": "ok", "delay": delay, "version": SERVICE_VERSION})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
