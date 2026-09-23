# Day 4 — Correlate Metrics, Logs, Traces, Profiles, Kubernetes and PostgreSQL

Day 3 proved that the EKS + GitOps + LGTM stack works. Day 4 is about **correlation**: start from a symptom and identify the exact service version, pod, node and database operation involved.

## What changed

The backend now publishes Kubernetes workload identity as OpenTelemetry resource attributes:

- `k8s.namespace.name`
- `k8s.pod.name`
- `k8s.pod.uid`
- `k8s.node.name`
- `service.version`

The OTel sidecar also runs the `k8sattributes` processor. It associates telemetry with the pod by `k8s.pod.uid` first and connection metadata second, then forwards:

```text
traces  -> Tempo
logs    -> Loki
metrics -> Mimir
profiles -> Pyroscope (direct from the Python SDK)
```

The collector uses a namespace-scoped Role rather than cluster-admin permissions.

## 1. Verify enrichment

After Argo CD syncs the new deployment:

```bash
kubectl rollout status deployment/backend -n application
kubectl get pods -n application -o wide
kubectl logs -n application deploy/backend -c otel-sidecar --tail=100
```

Generate traffic:

```bash
kubectl delete job loadgen -n application --ignore-not-found
kubectl apply -f deploy/dev/loadgen.yaml
```

## 2. Start from a slow request

In Grafana Explore, query the backend request duration metric and look for a latency increase. Then switch to Tempo and inspect a slow `backend.compute` trace.

For the selected trace, record:

```text
service.version
k8s.namespace.name
k8s.pod.name
k8s.pod.uid
k8s.node.name
```

The goal is to be able to say:

> This version, on this pod, on this node, produced the slow request.

## 3. Follow the trace into PostgreSQL

The same request contains child spans:

```text
backend.compute
postgres.schema.init   # first request only
postgres.insert
postgres.select
```

Compare their durations. If total request latency is high but PostgreSQL spans are fast, the database is not the bottleneck. If `postgres.insert` or `postgres.select` dominates the trace, investigate the DB path instead of scaling the web pods.

## 4. Correlate logs

Use the trace's time window and Kubernetes attributes in Loki. Search for:

```text
backend request failed
db write failed
db read failed
```

For a failed request, confirm that the log and trace agree on:

```text
service.version
k8s.pod.name
k8s.namespace.name
```

This is the practical reason for metadata enrichment: logs from ten identical replicas are much less useful if you cannot identify which replica emitted them.

## 5. Check profiles before scaling

Open Pyroscope and compare CPU profiles for `day3.backend`. The application profile tags now include:

```text
service
version
environment
namespace
pod
node
```

A latency incident with low CPU and a sleeping `backend.compute` span is an application-delay problem, not a CPU-capacity problem.

## 6. PostgreSQL telemetry exercise

The application emits:

```text
backend.db.operations
backend.db.operation.duration
```

with attributes:

```text
db.system.name=postgresql
db.operation.name=schema_init|insert|select
db.operation.status=ok|error
```

Use these alongside the PostgreSQL spans. The lab intentionally starts with application-observed DB telemetry because it answers the request-path question directly. AWS/RDS host metrics can be added afterward to answer infrastructure questions such as CPU, connections, free storage and I/O pressure.

## 7. Failure experiment

Create one controlled failure at a time:

### A. Application latency

Change the synthetic delay in `app/app.py` to a slower range and push to `dev`.

Expected evidence:

```text
new Git SHA
-> new service.version
-> latency rises
-> backend.compute span becomes slow
-> DB spans remain relatively normal
-> CPU profile does not justify scaling
```

### B. Database failure

Temporarily make the DB security path unavailable or use an invalid DB endpoint in a disposable lab only.

Expected evidence:

```text
HTTP 503
-> postgres span error
-> backend.db.operations{status=error}
-> matching application error log
-> same pod/version metadata across signals
```

Restore the database configuration immediately after the exercise.

## 8. Success criteria

You complete Day 4 when, from one bad request, you can identify all of these without guessing:

```text
Git/service version
Kubernetes namespace
pod
node
trace and slow span
matching log
profile context
PostgreSQL operation and duration
```

The next step is infrastructure-side RDS/CloudWatch metrics plus SLO/error-budget alerts, so application symptoms and AWS resource pressure can be compared in the same incident.
