resource "aws_lb_target_group" "worker" {
  for_each = var.workers

  name        = local.worker_target_group_names[each.key]
  port        = each.value.node_port
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = var.worker_vpc_id

  deregistration_delay = 30

  health_check {
    enabled             = true
    protocol            = "HTTP"
    port                = "traffic-port"
    path                = "/health"
    matcher             = "200"
    interval            = 30
    timeout             = 6
    healthy_threshold   = 3
    unhealthy_threshold = 2
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Worker   = each.key
    NodePort = tostring(each.value.node_port)
  }

  depends_on = [terraform_data.validated_inputs]
}

resource "aws_lb_target_group_attachment" "worker" {
  for_each = var.workers

  target_group_arn = aws_lb_target_group.worker[each.key].arn
  target_id        = var.worker_instance_id
  port             = each.value.node_port
}

resource "aws_lb" "worker" {
  for_each = var.workers

  name               = local.worker_nlb_names[each.key]
  internal           = true
  load_balancer_type = "network"
  subnets            = sort(tolist(var.worker_subnet_ids))
  security_groups    = [local.nlb_security_group_id]

  enable_cross_zone_load_balancing = var.enable_cross_zone_load_balancing
  enable_deletion_protection       = var.enable_deletion_protection

  tags = {
    Worker   = each.key
    NodePort = tostring(each.value.node_port)
  }

  depends_on = [terraform_data.validated_inputs]
}

resource "aws_lb_listener" "worker_tls" {
  for_each = var.workers

  load_balancer_arn = aws_lb.worker[each.key].arn
  port              = 443
  protocol          = "TLS"
  certificate_arn   = local.effective_certificate_arn
  ssl_policy        = var.tls_security_policy

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.worker[each.key].arn
  }
}
