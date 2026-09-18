data "external" "tf_state_bucket" {
  program = [
    "bash",
    "-c",
    "test -n \"$TF_STATE_BUCKET\" && printf '{\"bucket\":\"%s\"}\\n' \"$TF_STATE_BUCKET\""
  ]
}

data "aws_s3_bucket" "telemetry" {
  bucket = data.external.tf_state_bucket.result.bucket
}

locals {
  # Loki/Tempo/Pyroscope support slash-delimited prefixes. Mimir's storage_prefix
  # accepts alphanumeric characters only, so its three native stores use distinct
  # root prefixes in the same shared bucket.
  telemetry_prefixes = {
    loki      = "telemetry/loki"
    tempo     = "telemetry/tempo"
    mimir     = "telemetrymimir"
    pyroscope = "telemetry/pyroscope"
  }
}

resource "aws_iam_role" "telemetry_s3" {
  for_each = local.telemetry_prefixes

  name = "${var.cluster_name}-${each.key}-s3"

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

  tags = merge(local.tags, {
    Component = each.key
  })
}

resource "aws_iam_role_policy" "telemetry_s3" {
  for_each = local.telemetry_prefixes

  name = "${each.key}-s3-access"
  role = aws_iam_role.telemetry_s3[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BucketMetadata"
        Effect = "Allow"
        Action = [
          "s3:GetBucketLocation",
          "s3:ListBucketMultipartUploads"
        ]
        Resource = data.aws_s3_bucket.telemetry.arn
      },
      {
        Sid      = "ListComponentPrefix"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = data.aws_s3_bucket.telemetry.arn
        Condition = {
          StringLike = {
            "s3:prefix" = each.key == "mimir" ? [
              "telemetrymimir*"
            ] : [
              each.value,
              "${each.value}/*"
            ]
          }
        }
      },
      {
        Sid    = "ReadWriteComponentObjects"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:GetObjectTagging",
          "s3:PutObjectTagging",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts"
        ]
        Resource = each.key == "mimir"
          ? "${data.aws_s3_bucket.telemetry.arn}/telemetrymimir*"
          : "${data.aws_s3_bucket.telemetry.arn}/${each.value}/*"
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "telemetry_s3" {
  for_each = local.telemetry_prefixes

  cluster_name    = module.eks.cluster_name
  namespace       = "observability"
  service_account = each.key
  role_arn        = aws_iam_role.telemetry_s3[each.key].arn
}
