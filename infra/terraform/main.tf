data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # Public worker subnets are deliberate for this short-lived lab so we can avoid
  # a NAT Gateway. Do not copy this layout blindly into production.
  public_subnets = [
    cidrsubnet(var.vpc_cidr, 8, 1),
    cidrsubnet(var.vpc_cidr, 8, 2),
  ]

  # RDS stays private. These subnets have no NAT/IGW route created for them.
  private_subnets = [
    cidrsubnet(var.vpc_cidr, 8, 11),
    cidrsubnet(var.vpc_cidr, 8, 12),
  ]

  tags = {
    Project     = "day3-cicd-lgtm"
    Environment = "dev"
    ManagedBy   = "terraform"
  }

  # One-time/rebaseline candidate set. The benchmark workflow creates one
  # tainted node for each candidate plus one small system node, runs the same
  # workload on every candidate, then removes these groups after selection.
  benchmark_candidates = {
    "t4g-medium" = {
      instance_type = "t4g.medium"
      ami_type       = "AL2023_ARM_64_STANDARD"
      architecture   = "arm64"
    }
    "c7g-large" = {
      instance_type = "c7g.large"
      ami_type       = "AL2023_ARM_64_STANDARD"
      architecture   = "arm64"
    }
    "m7g-large" = {
      instance_type = "m7g.large"
      ami_type       = "AL2023_ARM_64_STANDARD"
      architecture   = "arm64"
    }
    "t3-medium" = {
      instance_type = "t3.medium"
      ami_type       = "AL2023_x86_64_STANDARD"
      architecture   = "amd64"
    }
    "c7i-large" = {
      instance_type = "c7i.large"
      ami_type       = "AL2023_x86_64_STANDARD"
      architecture   = "amd64"
    }
    "m7i-large" = {
      instance_type = "m7i.large"
      ami_type       = "AL2023_x86_64_STANDARD"
      architecture   = "amd64"
    }
  }

  selected_node_ami_type = contains([
    "t4g.medium",
    "c7g.large",
    "m7g.large",
  ], var.selected_node_instance_type) ? "AL2023_ARM_64_STANDARD" : "AL2023_x86_64_STANDARD"

  benchmark_node_groups = {
    for name, candidate in local.benchmark_candidates : "bench-${name}" => {
      create         = var.benchmark_mode
      ami_type       = candidate.ami_type
      instance_types = [candidate.instance_type]
      capacity_type  = "ON_DEMAND"
      min_size       = 1
      desired_size   = 1
      max_size       = 1
      subnet_ids     = module.vpc.public_subnets

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = var.node_disk_size_gib
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      labels = {
        workload                   = "capacity-benchmark"
        "capacity.candidate"       = name
        "capacity.instance-type"   = candidate.instance_type
        "kubernetes.io/arch-class" = candidate.architecture
      }

      taints = {
        benchmark = {
          key    = "capacity-benchmark"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }

      tags = merge(local.tags, {
        Component = "eks-benchmark-worker"
        Candidate = candidate.instance_type
      })
    }
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.1"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets

  enable_nat_gateway      = false
  enable_dns_support      = true
  enable_dns_hostnames    = true
  map_public_ip_on_launch = true

  tags = merge(local.tags, {
    Component = "network"
  })

  public_subnet_tags = merge(local.tags, {
    Component = "network"

    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.24"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  endpoint_public_access = true
  tags = merge(local.tags, {
    Component = "eks-control-plane"
  })

  # Adds the Terraform caller as an EKS access entry with cluster admin access.
  enable_cluster_creator_admin_permissions = true

  enabled_log_types = var.enable_control_plane_logs ? [
    "api",
    "audit",
    "authenticator",
  ] : []

  addons = {
    vpc-cni = {
      before_compute = true
      most_recent    = true
    }

    kube-proxy = {
      most_recent = true
    }

    coredns = {
      most_recent = true
    }

    metrics-server = {
      most_recent = true
    }

    eks-pod-identity-agent = {
      most_recent = true
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  eks_managed_node_groups = merge(
    {
      lab = {
        create         = !var.benchmark_mode
        ami_type       = local.selected_node_ami_type
        instance_types = [var.selected_node_instance_type]
        capacity_type  = "ON_DEMAND"

        min_size     = var.node_min_size
        desired_size = var.node_desired_size
        max_size     = var.node_max_size

        subnet_ids = module.vpc.public_subnets

        block_device_mappings = {
          xvda = {
            device_name = "/dev/xvda"
            ebs = {
              volume_size           = var.node_disk_size_gib
              volume_type           = "gp3"
              encrypted             = true
              delete_on_termination = true
            }
          }
        }

        labels = {
          workload                  = "day3-lab"
          "capacity.instance-type"  = var.selected_node_instance_type
        }

        tags = merge(local.tags, {
          Component = "eks-workers"
          Selected  = var.selected_node_instance_type
        })
      }

      # Keeps CoreDNS, metrics-server and other non-benchmark pods off the
      # tainted candidate nodes while the one-time benchmark is running.
      benchmark-system = {
        create         = var.benchmark_mode
        ami_type       = "AL2023_x86_64_STANDARD"
        instance_types = ["t3.medium"]
        capacity_type  = "ON_DEMAND"
        min_size       = 1
        desired_size   = 1
        max_size       = 1
        subnet_ids     = module.vpc.public_subnets

        labels = {
          workload = "benchmark-system"
        }

        tags = merge(local.tags, {
          Component = "eks-benchmark-system"
        })
      }
    },
    local.benchmark_node_groups,
  )
}

resource "aws_db_subnet_group" "postgres" {
  name       = "${var.cluster_name}-postgres"
  subnet_ids = module.vpc.private_subnets

  tags = merge(local.tags, {
    Name      = "${var.cluster_name}-postgres"
    Component = "database"
  })
}

resource "aws_security_group" "postgres" {
  name        = "${var.cluster_name}-postgres"
  description = "PostgreSQL access from EKS workers only"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "PostgreSQL from EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Component = "database"
  })
}

resource "aws_db_instance" "postgres" {
  identifier = "${var.cluster_name}-postgres"

  engine         = "postgres"
  instance_class = var.db_instance_class

  allocated_storage     = var.db_allocated_storage_gib
  max_allocated_storage = var.db_max_allocated_storage_gib
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.db_username
  port     = 5432

  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.postgres.name
  vpc_security_group_ids = [aws_security_group.postgres.id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true

  tags = merge(local.tags, {
    Component = "database"
  })
}

resource "aws_ecr_repository" "backend" {
  name                 = var.ecr_repository_name
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true
  tags = merge(local.tags, {
    Component = "registry"
  })

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "backend" {
  repository = aws_ecr_repository.backend.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only the 20 newest images in this lab repository"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 20
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
