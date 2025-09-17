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

# Summary - TF cannot guarentee remote state values for some resource type
# in our case, peer_vpc_id is always marked as - known after apply/ computed / tainted
# the workaround is - link the output from terraform_remote_state
# into this null resource and add a depends on to the actual block we are protecting (in this case aws_vpc_peering_connection)
# terraform PLAN marks the resource as changed (peer_vpc_id)
# but also the null_resource block as changed (as it relies on it)
# aws_vpc_peering_connection - with the depends on , makes TF understand it cannot determine peer_vpc_id
# on the apply-> the null resource will get the identical update from the remote_state output
# and then, when its time to handle the protected resource-> terraform will realize the value did not change
resource "null_resource" "remote_state_trigger" {
  # The 'triggers' argument is the key here.
  # We provide a map of attributes from the remote state.
  # If any of these attributes change, the null_resource is marked for replacement.
  # This replacement triggers the 'depends_on' relationship below.
  triggers = {
    # Reference the specific output that is causing the problem.
    # We include `data.terraform_remote_state.main.outputs.vpc_id`
    # as the value. Terraform will see this as a dependency.
    vpc_id_trigger = try(data.terraform_remote_state.main.outputs.vpc_id, "fake-id")
    
    # You can include other outputs here if they also cause issues.
    # subnet_ids_trigger = join(",", data.terraform_remote_state.main.outputs.subnet_ids)
  }
}

# Create VPC Peering Connection Request
resource "aws_vpc_peering_connection" "to_main" {
  #count = length(data.terraform_remote_state.main) > 0 ? 1 : 0

  vpc_id      = var.source_vpc_id
  #peer_vpc_id = local.peer_vpc_var
  #peer_vpc_id = "vpc-02511fd1cae3c0d6e"
  #peer_vpc_id = try(data.terraform_remote_state.main.outputs.main_vpc_info.vpc_id, "fake-id")  # fake-id Prevents validation error
  #peer_vpc_id = data.terraform_remote_state.main.outputs.main_vpc_info.vpc_id
  peer_vpc_id = data.terraform_remote_state.main.outputs.vpc_id
  #peer_region = try(data.terraform_remote_state.main.outputs.main_vpc_info.region, "fake-region") # fake-region fake region that will never be applied
  #auto_accept = true  # Changed to true - will remove the module from the other TF job

  tags = {
    Name        = "${var.project_tag}-${var.environment}-to-main-peering"
    Project     = var.project_tag
    Environment = var.environment
    Purpose     = "runner-to-main-vpc-peering"
    Side        = "requester"
  }

  depends_on = [
    null_resource.validate_outputs_or_fail,
    null_resource.remote_state_trigger
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
