# Cluster FinOps

This lab uses three cost views:

1. **C3X in CI** — estimates Terraform-managed monthly cost before apply.
2. **AWS Cost Explorer** — reports actual month-to-date project spend by service, component, usage type, and day.
3. **CUR 2.0** — optional hourly resource-level export with EKS split cost allocation data for pod/namespace analysis.

## Cost tags

AWS infrastructure and Kubernetes-created load balancers use:

- `Project=day3-cicd-lgtm`
- `Environment=dev`
- `Component=<cost owner>`

Current components include:

- `eks-control-plane`
- `eks-workers`
- `network`
- `database`
- `registry`
- `app-load-balancer`
- `grafana-load-balancer`
- telemetry backend role components such as `loki`, `tempo`, `mimir`, and `pyroscope`

## GitHub configuration

Repository variables:

```text
ENABLE_AWS_FINOPS=true
MONTHLY_BUDGET_USD=400
BUDGET_ALERT_EMAIL=<your email>
ENABLE_AWS_COST_REPORT=true
MONTHLY_COST_LIMIT_USD=400
ENABLE_CUR2_EXPORT=true
```

The normal build workflow uses open-source C3X and `MONTHLY_COST_LIMIT_USD` as a pre-deploy projected-cost gate. C3X requires no API key.
The `FinOps - Cluster Cost Breakdown` workflow uses `MONTHLY_BUDGET_USD` for the actual month-to-date guardrail.

## AWS IAM permissions

The GitHub Terraform role needs its normal infrastructure permissions plus the billing actions used by the enabled features.

Cost Explorer report:

```text
ce:GetCostAndUsage
```

Cost-allocation tag activation and budget management require the corresponding Cost Explorer/Budgets permissions.

CUR 2.0 requires BCM Data Exports and S3 permissions for the dedicated report bucket.

## EKS split cost allocation

This cluster uses **Resource requests** as the EKS split-cost allocation method.

Configure it once in:

```text
Billing and Cost Management
→ Cost Management preferences
→ Split cost allocation data
→ Amazon EKS
→ Resource requests
```

AWS will allocate shared worker-node cost using container CPU, memory, and accelerator requests. This is the preferred option for this lab because it does not require Amazon Managed Service for Prometheus or CloudWatch Container Insights.

All repository-owned workloads currently define CPU and memory requests:

- backend application
- OTel sidecar
- Loki
- Tempo
- Mimir
- Pyroscope
- Grafana

The pods also carry stable labels:

```text
cost-project=day3-cicd-lgtm
cost-component=<backend|loki|tempo|mimir|pyroscope|grafana>
environment=dev
```

CUR 2.0 is configured to include split-cost allocation data, split-line-item fields, and resource tags. This allows shared EC2 worker cost to be analyzed by cluster, namespace, workload, pod, and cost labels in Athena.

Cost Explorer does not expose the EKS pod-level split data; use CUR 2.0 for that analysis.

## Reports

### Pre-deploy

The main CI workflow:

```text
terraform plan
→ terraform show -json
→ C3X
→ optional monthly projected-cost gate
→ terraform apply
```

### Actual AWS spend

Run:

```text
Actions
→ FinOps - Cluster Cost Breakdown
→ Run workflow
```

The summary contains:

- month-to-date unblended cost
- month-to-date amortized cost
- simple month-end run rate
- budget consumption
- cost by AWS service
- cost by cluster component
- top AWS usage types
- daily burn

The workflow also runs every Monday.

## Important limitation

Tag-based reports only become complete after AWS cost-allocation tags are active and tagged usage has appeared in billing data. CUR/Cost Explorer data is not instantaneous.

The current infrastructure has Terraform state drift from the recent partial destroy/recreate attempt. Resolve that separately before interpreting a failed infrastructure workflow as a FinOps-code failure.
