terraform {
  backend "s3" {
    key          = "terraform/day3/dev/terraform.tfstate"
    region       = "ap-southeast-1"
    encrypt      = true
    use_lockfile = true
  }
}