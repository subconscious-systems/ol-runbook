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

output "gateway_worker_egress_helm_values_yaml" {
  description = "Merge this Helm values snippet into the gateway release to permit worker-VPC TCP 443 egress when its egress NetworkPolicy is enabled."
  value = yamlencode({
    networkPolicy = {
      egress = {
        additionalRules = [
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
