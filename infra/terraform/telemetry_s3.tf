locals {
  telemetry_buckets = {
    loki      = "${var.cluster_name}-${data.aws_caller_identity.current.account_id}-${var.aws_region}-loki"
    tempo     = "${var.cluster_name}-${data.aws_caller_identity.current.account_id}-${var.aws_region}-tempo"
    mimir     = "${var.cluster_name}-${data.aws_caller_identity.current.account_id}-${var.aws_region}-mimir"
    pyroscope = "${var.cluster_name}-${data.aws_caller_identity.current.account_id}-${var.aws_region}-pyroscope"
  }
}

resource "aws_s3_bucket" "telemetry" {
  for_each = local.telemetry_buckets

  bucket        = each.value
  force_destroy = true

  tags = merge(local.tags, {
    TelemetryBackend = each.key
  })
}

resource "aws_s3_bucket_public_access_block" "telemetry" {
  for_each = aws_s3_bucket.telemetry

  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "telemetry" {
  for_each = aws_s3_bucket.telemetry

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "telemetry" {
  for_each = aws_s3_bucket.telemetry

  bucket = each.value.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "telemetry" {
  for_each = aws_s3_bucket.telemetry

  bucket = each.value.id

  rule {
    id     = "expire-lab-telemetry"
    status = "Enabled"

    filter {}

    expiration {
      days = var.telemetry_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = var.telemetry_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.telemetry]
}

resource "aws_iam_role" "telemetry_s3" {
  name = "${var.cluster_name}-telemetry-s3"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "telemetry_s3" {
  name = "telemetry-s3-access"
  role = aws_iam_role.telemetry_s3.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ListTelemetryBuckets"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [for bucket in aws_s3_bucket.telemetry : bucket.arn]
      },
      {
        Sid    = "ReadWriteTelemetryObjects"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = [for bucket in aws_s3_bucket.telemetry : "${bucket.arn}/*"]
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "telemetry_s3" {
  cluster_name    = module.eks.cluster_name
  namespace       = "observability"
  service_account = "telemetry-backends"
  role_arn        = aws_iam_role.telemetry_s3.arn
}
