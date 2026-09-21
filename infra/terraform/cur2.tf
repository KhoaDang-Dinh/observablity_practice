resource "aws_s3_bucket" "cur2" {
  count    = var.enable_cur2_export ? 1 : 0
  provider = aws.billing

  bucket = "${var.cluster_name}-cur2-${data.aws_caller_identity.current.account_id}"

  tags = merge(local.tags, {
    Purpose = "cur2-cost-export"
  })
}

resource "aws_s3_bucket_public_access_block" "cur2" {
  count    = var.enable_cur2_export ? 1 : 0
  provider = aws.billing

  bucket                  = aws_s3_bucket.cur2[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cur2" {
  count    = var.enable_cur2_export ? 1 : 0
  provider = aws.billing

  bucket = aws_s3_bucket.cur2[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "cur2" {
  count    = var.enable_cur2_export ? 1 : 0
  provider = aws.billing

  bucket = aws_s3_bucket.cur2[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableAWSDataExportsToWriteToS3"
        Effect = "Allow"
        Principal = {
          Service = "bcm-data-exports.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cur2[0].arn}/*"
        Condition = {
          ArnLike = {
            "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:bcm-data-exports:us-east-1:${data.aws_caller_identity.current.account_id}:export/*"
          }
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

resource "aws_bcmdataexports_export" "cur2" {
  count    = var.enable_cur2_export ? 1 : 0
  provider = aws.billing

  export {
    name        = "${var.cluster_name}-cur2"
    description = "Hourly CUR 2.0 export for cluster FinOps analysis"

    data_query {
      query_statement = "SELECT identity_line_item_id, identity_time_interval, bill_payer_account_id, line_item_usage_account_id, line_item_resource_id, line_item_product_code, line_item_usage_type, line_item_operation, line_item_unblended_cost, line_item_unblended_rate, pricing_unit FROM COST_AND_USAGE_REPORT"

      table_configurations = {
        COST_AND_USAGE_REPORT = {
          BILLING_VIEW_ARN                      = "arn:${data.aws_partition.current.partition}:billing::${data.aws_caller_identity.current.account_id}:billingview/primary"
          TIME_GRANULARITY                      = "HOURLY"
          INCLUDE_RESOURCES                     = "TRUE"
          INCLUDE_MANUAL_DISCOUNT_COMPATIBILITY = "FALSE"
          INCLUDE_SPLIT_COST_ALLOCATION_DATA    = "TRUE"
        }
      }
    }

    destination_configurations {
      s3_destination {
        s3_bucket = aws_s3_bucket.cur2[0].bucket
        s3_prefix = "cur2"
        s3_region = "us-east-1"

        s3_output_configurations {
          overwrite   = "CREATE_NEW_REPORT"
          format      = "PARQUET"
          compression = "PARQUET"
          output_type = "CUSTOM"
        }
      }
    }

    refresh_cadence {
      frequency = "SYNCHRONOUS"
    }
  }

  depends_on = [aws_s3_bucket_policy.cur2]
}
