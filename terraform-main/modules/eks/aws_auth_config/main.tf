# terraform-main/modules/eks/aws_auth_config/main.tf

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.12.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38.0"
    }
  }
}
#
# Read existing aws-auth configmap to preserve node group roles
data "kubernetes_config_map_v1" "existing_aws_auth" {
  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
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

resource "null_resource" "validate_outputs_or_fail" {
  #count = var.initialize_run ? 0 : 1

  provisioner "local-exec" {
    command = <<-EOF
      # Check all required outputs for the module
      RUNNER_ROLE_ARN="${try(data.terraform_remote_state.runner_infra.outputs.runner_instance_role_arn, "")}"
      
      
      if [ -z "$RUNNER_ROLE_ARN" ] ; then
        echo "ERROR: Required outputs missing from main terraform state:"
        echo "  RUNNER_ROLE_ARN: $RUNNER_ROLE_ARN" 
        echo "Cannot proceed with the module - runner infrastructure outputs incomplete"
        echo "Run 'terraform apply' on main infrastructure first"
        exit 1
      fi
      
      echo "Validation passed - all required outputs present"
      echo "RUNNER_ROLE_ARN: $RUNNER_ROLE_ARN"
    EOF
  }
}

# resource "null_resource" "validate_runner_outputs" {
#   provisioner "local-exec" {
#     command = <<-EOF
#       if [ "${local.github_runner_role_arn}" = "arn:aws:iam::123456789012:role/my-fake-role" ] || [ "${local.github_runner_role_arn}" = "not-found" ]; then
#         echo "ERROR: Required runner_instance_role_arn missing from runner infrastructure state"
#         echo "This usually means:"
#         echo "  1. Runner infrastructure hasn't been deployed yet"
#         echo "  2. Runner infrastructure state is missing outputs" 
#         echo "  3. initialize_run=true on runner infrastructure"
#         echo "  4. No github-runner user found in map_roles"
#         echo ""
#         echo "Run 'terraform apply' on runner infrastructure first with initialize_run=false"
#         exit 1
#       fi
      
#       echo "✅ Runner infrastructure outputs validated"
#       echo "Runner Role ARN: ${local.github_runner_role_arn}"
#     EOF
#   }
# }

locals {
  runner_arn = try(data.terraform_remote_state.runner_infra.outputs.runner_instance_role_arn, "BAD")
  
  updated_map_roles = [
    for role in var.map_roles : {
      rolearn = (
        role.username == "github-runner" && 
        role.rolearn == "arn:aws:iam::123456789012:role/my-fake-role" &&
        local.runner_arn != "BAD"
      ) ? local.runner_arn : role.rolearn
      
      username = role.username
      groups   = role.groups
    }
  ]

  # Parse existing mapRoles
  existing_map_roles = try(yamldecode(data.kubernetes_config_map_v1.existing_aws_auth.data["mapRoles"]), [])
  existing_map_users = try(yamldecode(data.kubernetes_config_map_v1.existing_aws_auth.data["mapUsers"]), [])
  
  # Get unique role ARNs and user ARNs from existing configmap
  existing_role_arns = toset([for role in local.existing_map_roles : role.rolearn])
  existing_user_arns = toset([for user in local.existing_map_users : user.userarn])
  
  # # Only add new roles that don't already exist
  # new_roles = [
  #   for role in var.map_roles : role 
  #   if !contains(local.existing_role_arns, role.rolearn)
  # ]

  # Only add new roles that don't already exist
  new_roles = [
    for role in local.updated_map_roles : role 
      if !contains(local.existing_role_arns, role.rolearn)
  ]
  
  # Only add new users that don't already exist  
  new_users = [
    for user_key, user in var.eks_user_access_map : {
      userarn  = user.userarn
      username = user.username
      groups   = user.groups
    } if !contains(local.existing_user_arns, user.userarn)
  ]
  
  # Merge existing + new (no duplicates)
  merged_map_roles = concat(local.existing_map_roles, local.new_roles)
  merged_map_users = concat(local.existing_map_users, local.new_users)

  # # Find the github-runner role ARN from the map_roles array
  # github_runner_role_arn = try([for role in var.map_roles : role.rolearn if role.username == "github-runner"][0], "not-found")
}

resource "kubernetes_config_map_v1_data" "aws_auth_patch" {
  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
  }

  data = {
    mapRoles = yamlencode(local.merged_map_roles)
    mapUsers = yamlencode(local.merged_map_users)
  }

  force = true
  
  depends_on = [
    data.kubernetes_config_map_v1.existing_aws_auth,
    null_resource.validate_outputs_or_fail
  ]
}
