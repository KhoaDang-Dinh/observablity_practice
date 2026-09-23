# Pre-deployment gates

The dev pipeline now promotes a backend image only after these gates pass:

```text
source
  -> Python syntax
  -> Semgrep SAST
  -> Trivy secrets + dependency scan
  -> Trivy IaC report
  -> Terraform plan/cost gate
  -> build image
  -> Trivy image gate
  -> push candidate image
  -> isolated EKS predeploy namespace
  -> OWASP ZAP API DAST
  -> k6 performance thresholds
  -> GitOps promotion commit
  -> Argo CD rollout
  -> observability verification
```

The critical design rule is that building and pushing an image does not promote it.
Only the `promote` job updates `deploy/dev/backend.yaml`, and that job depends on
the dynamic security and performance gate.

The current k6 thresholds reflect the lab application's deliberate ~10% synthetic
failure rate. Tighten the error threshold after disabling that fault injection.
