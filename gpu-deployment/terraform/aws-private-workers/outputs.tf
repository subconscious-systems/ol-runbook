output "vpc_peering_connection_id" {
  description = "Gateway-to-worker VPC peering connection."
  value       = local.vpc_peering_connection_id
}

output "nlb_security_group_id" {
  description = "Reusable security group attached to every private worker NLB."
  value       = local.nlb_security_group_id
}

output "certificate_arn" {
  description = "Wildcard ACM certificate attached to worker TLS listeners."
  value       = local.effective_certificate_arn
}

output "gateway_route_allowed_host_suffix" {
  description = "Add this suffix to the gateway routeAllowedHostSuffixes setting."
  value       = var.worker_domain
}

output "gateway_worker_egress_network_policy_yaml" {
  description = "Scoped additive NetworkPolicy YAML; apply it to permit gateway/router/adapter TCP 443 egress to worker VPC CIDRs."
  value = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = var.gateway_network_policy_name
      namespace = var.gateway_namespace
      labels = {
        "app.kubernetes.io/instance"   = var.gateway_release_name
        "app.kubernetes.io/managed-by" = "terraform-output"
        "app.kubernetes.io/name"       = "api-gateway"
      }
    }
    spec = {
      podSelector = {
        matchExpressions = [
          {
            key      = "app.kubernetes.io/instance"
            operator = "In"
            values   = [var.gateway_release_name]
          },
          {
            key      = "app.kubernetes.io/component"
            operator = "In"
            values   = ["gateway", "router", "adapter"]
          },
        ]
      }
      policyTypes = ["Egress"]
      egress = [
        for cidr in sort(tolist(local.worker_vpc_cidrs)) : {
          to = [
            {
              ipBlock = {
                cidr = cidr
              }
            }
          ]
          ports = [
            {
              protocol = "TCP"
              port     = 443
            }
          ]
        }
      ]
    }
  })
}

output "worker_endpoints" {
  description = "Worker endpoint details for the API gateway dashboard."
  value = {
    for name, worker in var.workers :
    name => {
      url              = "https://${name}.${var.worker_domain}"
      node_port        = worker.node_port
      nlb_dns_name     = aws_lb.worker[name].dns_name
      target_group_arn = aws_lb_target_group.worker[name].arn
    }
  }
}
