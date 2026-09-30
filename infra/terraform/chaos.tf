resource "aws_iam_role" "fis_az_failure" {
  name = "${var.cluster_name}-fis-az-failure"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "fis.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(local.tags, {
    Component = "chaos-engineering"
  })
}

resource "aws_iam_role_policy_attachment" "fis_ec2" {
  role       = aws_iam_role.fis_az_failure.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSFaultInjectionSimulatorEC2Access"
}

resource "aws_iam_role_policy_attachment" "fis_network" {
  role       = aws_iam_role.fis_az_failure.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSFaultInjectionSimulatorNetworkAccess"
}
