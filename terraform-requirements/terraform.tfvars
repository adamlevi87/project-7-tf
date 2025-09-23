# terraform-requirements/terraform.tfvars

aws_region = "us-east-1"
environment = "dev"
aws_dynamodb_table_name = "project-7-terraform-locks"
github_org = "adamlevi87"
github_repo = "project-7-tf"
aws_s3_bucket_name = "project-7-tf-state"
aws_iam_role_github_actions_name = "initial-role-for-tf"
project_tag= "project-7"

kms_allowed_users =[
    "adam.local",
    "adam.login"
  ]