data "aws_s3_bucket" "telemetry" {
  bucket = var.telemetry_bucket_name
}

locals {
  telemetry_prefixes = {
    loki      = "telemetry/loki"
    tempo     = "telemetry/tempo"
    mimir     = "telemetry/mimir"
    pyroscope = "telemetry/pyroscope"
  }
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
        Sid      = "GetTelemetryBucketLocation"
        Effect   = "Allow"
        Action   = "s3:GetBucketLocation"
        Resource = data.aws_s3_bucket.telemetry.arn
      },
      {
        Sid    = "ListTelemetryPrefix"
        Effect = "Allow"
        Action = "s3:ListBucket"
        Resource = data.aws_s3_bucket.telemetry.arn
        Condition = {
          StringLike = {
            "s3:prefix" = [
              "telemetry",
              "telemetry/*"
            ]
          }
        }
      },
      {
        Sid    = "ReadWriteTelemetryObjects"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = "${data.aws_s3_bucket.telemetry.arn}/telemetry/*"
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
