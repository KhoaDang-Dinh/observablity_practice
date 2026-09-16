# Day 3 — CI/CD + OpenTelemetry + LGTM on EKS

This is a **lab/demo** repo, not a production observability architecture.

## Architecture

```text
push app/**
   |
GitHub Actions --OIDC--> AWS
   |                    |
   |                 ECR image
   |                    |
   +--commit SHA--------+
          |
        Git dev branch
          |
        Argo CD
          |
          v
         EKS
    +-----+-------------------+
    |                         |
 backend                 grafana/otel-lgtm
    |                   (OTel + Loki + Mimir/metrics + Tempo + Grafana)
    +---- OTLP 4317 ----------+
```

The app also exposes `/metrics` in Prometheus text format for a later scrape exercise.

## 1. Bootstrap manually once

Create namespaces and LGTM first if Argo CD is not installed yet:

```bash
kubectl apply -f deploy/dev/namespace.yaml
kubectl apply -f deploy/dev/lgtm.yaml
kubectl rollout status deployment/lgtm -n observability
```

## 2. GitHub OIDC prerequisites

Create an AWS IAM role trusted by GitHub OIDC and give it only the ECR permissions needed for this lab. Save its ARN as repository secret:

```text
AWS_ROLE_ARN
```

The workflow creates `day3-backend` in ECR if it does not exist.

## 3. First image

Push any change under `app/` to branch `dev`. GitHub Actions will:

1. build the image
2. push it to ECR with the Git SHA
3. update `deploy/dev/backend.yaml`
4. commit the desired image SHA back to `dev`

## 4. Argo CD

Replace the repo URL:

```bash
sed -i 's#REPLACE_WITH_GITHUB_REPO_URL#https://github.com/YOUR_USER/YOUR_REPO.git#' argocd/application.yaml
kubectl apply -f argocd/application.yaml
```

After that, CI should not need `kubectl` access to EKS. Argo CD reads Git and deploys the desired state.

## 5. Generate traffic

```bash
kubectl delete job loadgen -n application --ignore-not-found
kubectl apply -f deploy/dev/loadgen.yaml
kubectl logs -n application job/loadgen -f
```

## 6. Resource/cost observation

```bash
kubectl top nodes
kubectl top pods -n application
kubectl top pods -n observability
```

Compare app overhead with observability overhead.

## 7. Browser access from AWS CloudShell

CloudShell cannot expose its local port-forward to your desktop browser. Temporarily create a public AWS load balancer:

```bash
kubectl apply -f deploy/dev/grafana-public.yaml
kubectl get svc grafana-public -n observability -w
```

Open the resulting ELB hostname. Default credentials for the demo image are normally `admin` / `admin`.

**Delete the LoadBalancer when finished because it costs money:**

```bash
kubectl delete -f deploy/dev/grafana-public.yaml
```

## 8. What to inspect in Grafana

### Traces / Tempo

Search for service `backend` and inspect `backend.compute`. Slow traces deliberately contain ~600 ms of application delay.

### Logs / Loki

Look for backend logs containing:

```text
backend request failed
```

The OTel resource includes `service.name=backend` and `service.version=<git-sha>` so you can correlate regressions with a deployment.

### Metrics

The app emits OTLP metrics and also exposes Prometheus-format metrics at:

```text
http://backend.application.svc.cluster.local:8080/metrics
```

To inspect the Prometheus endpoint directly:

```bash
kubectl run metrics-test -n application --rm -it --restart=Never \
  --image=curlimages/curl:8.16.0 -- \
  curl -s http://backend:8080/metrics
```

## 9. Day 3 failure experiment

Change this line in `app/app.py`:

```python
delay = random.choice([0.05, 0.08, 0.10, 0.15, 0.60])
```

to something deliberately bad such as:

```python
delay = random.choice([0.8, 1.0, 1.2])
```

Push to `dev`. Then prove:

```text
Git SHA changed
-> Argo CD deployed it
-> latency increased
-> traces point to backend.compute
-> logs show the new service.version
-> CPU may still be low
```

The correct response is rollback/fix the application, not automatically buy more EC2 capacity.

## Cleanup

```bash
kubectl delete -f deploy/dev/grafana-public.yaml --ignore-not-found
kubectl delete job loadgen -n application --ignore-not-found
```

For a temporary lab cluster, delete the entire EKS cluster when finished to stop the control-plane and node charges.

## 10. Create the AWS infrastructure with Terraform

The repo now contains `infra/terraform/` for the AWS foundation.

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
# Set github_repository = "OWNER/REPO"

terraform init
terraform plan
terraform apply

$(terraform output -raw update_kubeconfig_command)
kubectl get nodes
```

Terraform creates the VPC, EKS cluster, required EKS add-ons, managed worker node group, ECR repository, and a GitHub OIDC role restricted to the `dev` branch and this ECR repository.

Then put this output into the GitHub Actions secret `AWS_ROLE_ARN`:

```bash
terraform output -raw github_actions_role_arn
```

This keeps responsibilities clean:

```text
Terraform       = cloud infrastructure
GitHub Actions  = build/publish images
Argo CD         = Kubernetes deployment
LGTM/OTel       = runtime observability
```
