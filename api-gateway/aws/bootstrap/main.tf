data "aws_caller_identity" "current" {}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_security_group" "docker_agent" {
  name        = "${var.name_prefix}-docker-agent"
  description = "Distr Docker agent host (egress-only; SSM via AWS APIs)"
  vpc_id      = local.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-docker-agent"
  }
}

resource "aws_instance" "docker_agent" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.instance_type
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [aws_security_group.docker_agent.id]
  iam_instance_profile        = aws_iam_instance_profile.docker_agent.name
  associate_public_ip_address = true

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size_gb
    encrypted   = true
  }

  # First-boot only. Host setup changes are applied idempotently via
  # ./scripts/ensure-host.sh (SSM) — never by replacing this instance.
  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    host_setup_b64 = filebase64("${path.module}/scripts/host-setup.sh")
  })

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tags = {
    Name = "${var.name_prefix}-docker-agent"
  }

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

resource "aws_eip" "docker_agent" {
  domain   = "vpc"
  instance = aws_instance.docker_agent.id

  tags = {
    Name = "${var.name_prefix}-docker-agent"
  }
}
