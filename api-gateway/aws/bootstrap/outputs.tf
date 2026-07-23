output "instance_id" {
  description = "EC2 instance ID for the Docker agent host."
  value       = aws_instance.docker_agent.id
}

output "public_ip" {
  description = "Elastic IP of the Docker agent host."
  value       = aws_eip.docker_agent.public_ip
}

output "eip" {
  description = "Alias for public_ip (Elastic IP)."
  value       = aws_eip.docker_agent.public_ip
}

output "iam_role_arn" {
  description = "Instance role ARN used for platforms/aws Terraform apply."
  value       = aws_iam_role.docker_agent.arn
}

output "iam_instance_profile_arn" {
  description = "Instance profile ARN."
  value       = aws_iam_instance_profile.docker_agent.arn
}

output "suggested_cluster_endpoint_public_access_cidrs" {
  description = "Optional pin; runner auto-fills host public IP/32 when CIDRs are empty."
  value       = "${aws_eip.docker_agent.public_ip}/32"
}

output "ssm_start_session_command" {
  description = "Interactive SSM session (optional; prefer scripts/run-agent.sh)."
  value       = "aws ssm start-session --target ${aws_instance.docker_agent.id} --region ${var.aws_region}"
}

output "aws_region" {
  value = var.aws_region
}

output "account_id" {
  value = data.aws_caller_identity.current.account_id
}
