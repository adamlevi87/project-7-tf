# terraform-main/modules/vpc_peering/main.tf

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.12.0"
    }
  }
}

data "terraform_remote_state" "runner_infra" {
  #count = var.initialize_run ? 0 : 1
  
  backend = "s3"
  config = {
    bucket = "${var.project_tag}-tf-state"
    key    = "${var.project_tag}-tf/${var.environment}/runner-infra/terraform.tfstate"
    region = "${var.aws_region}"
  }
}
