# ADR-005: Benchmark-driven EKS node selection

## Status
Accepted for the EKS observability lab.

## Requirements

- Architecture constraint: Amazon EKS.
- Expected traffic: approximately 5,000 successful API requests per month.
- Burst/concurrency target: approximately 10 concurrent requests.
- Performance SLO: P95 end-to-end API latency <= 250 ms.
- CPU architecture: no legacy constraint; both arm64 and x86_64 are eligible.
- API: HTTP API exposed by the application.
- Primary optimization objective: lowest projected cost per successful request among candidates that satisfy the SLO.
- Autoscaling is a runtime mechanism and does not replace initial capacity right-sizing.

## Decision

Use a one-time/rebaseline workflow before normal deployment:

```text
static security gates
  -> create temporary EKS benchmark node groups
  -> build one multi-architecture image
  -> run identical 10-concurrency k6 workload on every node candidate
  -> reject candidates with P95 > 250 ms or >=1% request failure
  -> price only the passing candidates using Terraform plan + C3X
  -> choose the lowest projected monthly cost
  -> replace temporary benchmark nodes with the selected managed node group
  -> persist selected_node_instance_type
  -> start the normal deployment workflow
```

Candidate set:

- t4g.medium (arm64, burstable)
- c7g.large (arm64, compute optimized)
- m7g.large (arm64, general purpose)
- t3.medium (x86_64, burstable)
- c7i.large (x86_64, compute optimized)
- m7i.large (x86_64, general purpose)

The benchmark nodes are tainted so ordinary cluster workloads cannot consume them. A separate system node hosts CoreDNS and cluster add-ons during the benchmark.

## Benchmark behavior

The production `/work` path is retained, including PostgreSQL insert/select operations and OpenTelemetry instrumentation. Intentional demo chaos is disabled during right-sizing so the benchmark measures real capacity rather than the lab-only 600 ms synthetic delay and 10% synthetic error injection.

## Cost rule

Cost is evaluated only after performance qualification. A cheap candidate that violates the P95 SLO is not eligible.

For the expected workload:

```text
estimated_cost_per_request = projected_monthly_infrastructure_cost / 5000
```

Normal releases do not repeat the six-node benchmark. They reuse `infra/terraform/capacity.auto.tfvars.json`. Re-run the bootstrap workflow when the workload, dependencies, SLO, or resource profile changes materially.
