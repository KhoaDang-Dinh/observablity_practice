# Single-AZ Failure Recovery Runbook

This lab is intentionally **recoverable, not fully active-active**.

Normal operation keeps one EKS worker running. The managed node group is attached to public subnets in two Availability Zones and can scale to two workers. RDS remains Single-AZ to save cost, but automated backups/PITR are enabled.

## Recovery objectives

- EKS worker/AZ failure: replace the worker in the surviving AZ and recreate pods.
- Application state: recreated from GitOps/ECR.
- Observability history: recovered from S3-backed stores.
- RDS AZ failure: restore PostgreSQL from automated backup/PITR into a healthy AZ and update the Kubernetes database secret.
- No requirement for zero downtime.

## 1. Detect the failure

Grafana alerts should flag:

- EKS worker node NotReady
- backend unavailable
- backend metrics endpoint unavailable
- Mimir unavailable

Confirm with:

```bash
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get svc -n application
```

Check the managed node group:

```bash
aws eks list-nodegroups --cluster-name day3-observe
aws eks describe-nodegroup \
  --cluster-name day3-observe \
  --nodegroup-name lab
```

## 2. Compute-only/AZ failure

The normal node group is:

```text
min=1
desired=1
max=2
subnets=AZ-A + AZ-B
```

If the original worker disappears, the EC2 Auto Scaling group should launch a replacement in an available subnet/AZ.

Watch recovery:

```bash
watch -n 5 'kubectl get nodes -o wide; echo; kubectl get pods -A -o wide'
```

If replacement capacity is not being created, temporarily force desired capacity to 2:

```bash
aws eks update-nodegroup-config \
  --cluster-name day3-observe \
  --nodegroup-name lab \
  --scaling-config minSize=1,maxSize=2,desiredSize=2
```

After recovery and once the failed AZ is healthy again, Terraform should return the desired count to the repository baseline of 1.

## 3. Application recovery

Argo CD should recreate the application from Git.

Verify:

```bash
kubectl get application day3 -n argocd -o wide
kubectl rollout status deployment/backend -n application --timeout=10m
kubectl get pods -n application -o wide
```

The backend image is immutable in ECR and referenced by GitOps.

## 4. Observability recovery

Grafana, Mimir, Loki, Tempo, and Pyroscope may be unavailable while the replacement worker is starting.

They are treated as recoverable services rather than continuously available services.

Check:

```bash
kubectl get pods -n observability -o wide
kubectl rollout status deployment/grafana -n observability --timeout=10m
kubectl rollout status deployment/mimir -n observability --timeout=10m
```

Historical telemetry should reconnect to the S3-backed stores after the pods return.

## 5. RDS failure

RDS is intentionally Single-AZ.

Automated backups/PITR are enabled for the configured retention window.

Get the latest restorable time:

```bash
aws rds describe-db-instances \
  --db-instance-identifier day3-observe-postgres \
  --query 'DBInstances[0].[LatestRestorableTime,EarliestRestorableTime,AvailabilityZone,DBInstanceStatus]'
```

If the DB cannot recover in place, restore to the latest restorable point:

```bash
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier day3-observe-postgres \
  --target-db-instance-identifier day3-observe-postgres-recovery \
  --use-latest-restorable-time \
  --db-instance-class db.t3.large \
  --no-multi-az
```

Wait for the restored DB:

```bash
aws rds wait db-instance-available \
  --db-instance-identifier day3-observe-postgres-recovery
```

Fetch its endpoint:

```bash
aws rds describe-db-instances \
  --db-instance-identifier day3-observe-postgres-recovery \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text
```

Then update the Kubernetes `rds-postgres` secret with the new host and restart the backend.

The normal CI bootstrap already knows how to sync DB credentials from AWS Secrets Manager; for a manual emergency restore, update only the host while preserving the existing database name/user/password.

```bash
kubectl rollout restart deployment/backend -n application
kubectl rollout status deployment/backend -n application --timeout=10m
```

## 6. Validate recovery

```bash
kubectl get nodes
kubectl get pods -A
curl http://<APP-ENDPOINT>/health
curl http://<APP-ENDPOINT>/db
```

In Grafana verify:

- backend scrape = UP
- request rate is returning
- DB latency is populated
- node CPU/memory are present
- alerts have returned to Normal

## Recovery model

```text
AZ/worker loss
    |
    +--> EKS/ASG launches replacement worker in surviving AZ
    |       |
    |       +--> Argo/Kubernetes recreate pods
    |
    +--> If RDS survives: reconnect normally
    |
    +--> If RDS is lost: PITR restore -> new endpoint -> update secret -> restart backend
```

The design optimizes for low steady-state cost and predictable reconstruction, not zero-downtime HA.
