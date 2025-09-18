# terraform-main/modules/vpc_peering/main.tf

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.12.0"
    }
  }
}

# data "terraform_remote_state" "main" {
#   backend = "s3"
#   config = {
#     bucket = "${var.project_tag}-tf-state"
#     key    = "${var.project_tag}-tf/${var.environment}/main/terraform.tfstate"
#     region = "${var.aws_region}"
#   }
# }

data "terraform_remote_state" "main" {
  #count = var.initialize_run ? 0 : 1
  backend = "s3"
  config = {
    bucket = "${var.project_tag}-tf-state"
    key    = "${var.project_tag}-tf/${var.environment}/main/terraform.tfstate"
    region = "${var.aws_region}"
  }
}

resource "null_resource" "validate_outputs_or_fail" {
  #count = var.initialize_run ? 0 : 1

  provisioner "local-exec" {
    command = <<-EOF
      # Check all required outputs for VPC peering
      VPC_ID="${try(data.terraform_remote_state.main.outputs.main_vpc_info.vpc_id, "")}"
      REGION="${try(data.terraform_remote_state.main.outputs.main_vpc_info.region, "")}"
      VPC_CIDR="${try(data.terraform_remote_state.main.outputs.main_vpc_info.vpc_cidr_block, "")}"
      
      if [ -z "$VPC_ID" ] || [ -z "$VPC_CIDR" ] || [ -z "$REGION" ]; then
        echo "ERROR: Required outputs missing from main terraform state:"
        echo "  VPC ID: $VPC_ID"
        echo "  VPC CIDR: $VPC_CIDR" 
        echo "  Region: $REGION"
        echo "Cannot proceed with VPC peering - main infrastructure outputs incomplete"
        echo "Run 'terraform apply' on main infrastructure first"
        exit 1
      fi
      
      echo "Validation passed - all required outputs present"
      echo "VPC ID: $VPC_ID"
      echo "VPC CIDR: $VPC_CIDR"
      echo "Region: $REGION"
    EOF
  }
}


# Create VPC Peering Connection Request
resource "aws_vpc_peering_connection" "to_main" {
  #count = length(data.terraform_remote_state.main) > 0 ? 1 : 0

  vpc_id      = var.source_vpc_id
  peer_vpc_id = try(data.terraform_remote_state.main.outputs.main_vpc_info.vpc_id, "fake-id")  # fake-id Prevents validation error
  #peer_region = try(data.terraform_remote_state.main.outputs.main_vpc_info.region, "fake-region") # fake-region fake region that will never be applied
  auto_accept = true  # Changed to true - will remove the module from the other TF job

  tags = {
    Name        = "${var.project_tag}-${var.environment}-to-main-peering"
    Project     = var.project_tag
    Environment = var.environment
    Purpose     = "runner-to-main-vpc-peering"
    Side        = "requester"
  }

  depends_on = [
    null_resource.validate_outputs_or_fail
  ]
}

# resource "aws_vpc_peering_connection_options" "to_main" {
#   vpc_peering_connection_id = aws_vpc_peering_connection.to_main.id

#   accepter {
#     allow_remote_vpc_dns_resolution = false
#   }

#   depends_on = [ aws_vpc_peering_connection.to_main ]
# }

# Add route to main VPC through peering connection
resource "aws_route" "runner_to_main" {
  #count = length(data.terraform_remote_state.main) > 0 ? 1 : 0

  route_table_id            = var.source_route_table_id
  destination_cidr_block = try(data.terraform_remote_state.main.outputs.main_vpc_info.vpc_cidr_block, "10.255.255.0/24") # 10.255.255.0 - fake cidr will never be applied
  vpc_peering_connection_id = try(aws_vpc_peering_connection.to_main.id, "pcx-fakeid12345") 

  depends_on = [null_resource.validate_outputs_or_fail]
}
