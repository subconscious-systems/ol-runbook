variable "aws_region" {
  type        = string
  description = "AWS region for the Docker agent host (match platform AWS_REGION)."
  default     = "us-east-2"
}

variable "name_prefix" {
  type        = string
  description = "Name prefix for IAM / EC2 resources."
  default     = "api-gateway-infra"
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type (Terraform-in-Docker needs decent memory)."
  default     = "t3.large"
}

variable "root_volume_size_gb" {
  type        = number
  description = "Root EBS volume size (GiB)."
  default     = 40
}

variable "vpc_id" {
  type        = string
  description = "VPC for the agent host. Empty = account default VPC."
  default     = ""
}

variable "subnet_id" {
  type        = string
  description = "Public subnet for the agent host. Empty = first default-VPC public subnet."
  default     = ""
}
