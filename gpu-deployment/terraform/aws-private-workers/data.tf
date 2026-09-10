data "aws_vpc" "gateway" {
  id = var.gateway_vpc_id
}

data "aws_vpc" "worker" {
  id = var.worker_vpc_id
}

data "aws_instance" "worker" {
  instance_id = var.worker_instance_id
}

data "aws_subnet" "worker_instance" {
  id = data.aws_instance.worker.subnet_id
}

data "aws_subnet" "worker" {
  for_each = local.all_worker_subnet_ids
  id       = each.value
}

data "aws_subnet" "gateway" {
  for_each = var.gateway_subnet_ids
  id       = each.value
}

data "aws_route_tables" "gateway" {
  vpc_id = var.gateway_vpc_id
}

data "aws_route_table" "gateway" {
  for_each       = toset(data.aws_route_tables.gateway.ids)
  route_table_id = each.value
}

data "aws_route_tables" "worker" {
  vpc_id = var.worker_vpc_id
}

data "aws_route_table" "worker" {
  for_each       = toset(data.aws_route_tables.worker.ids)
  route_table_id = each.value
}

data "aws_route53_zone" "workers" {
  name         = var.route53_zone_name
  private_zone = false
}

data "aws_vpc_peering_connection" "existing" {
  count = var.existing_vpc_peering_connection_id != null ? 1 : 0
  id    = var.existing_vpc_peering_connection_id
}

data "aws_security_group" "existing_nlb" {
  count = var.existing_nlb_security_group_id != null ? 1 : 0
  id    = var.existing_nlb_security_group_id
}

data "aws_acm_certificate" "existing" {
  count       = var.certificate_arn != null ? 1 : 0
  domain      = "*.${var.worker_domain}"
  statuses    = ["ISSUED"]
  most_recent = true
}

resource "terraform_data" "validated_inputs" {
  lifecycle {
    precondition {
      condition = alltrue(flatten([
        for gateway_cidr, gateway_range in local.gateway_cidr_ranges : [
          for worker_cidr, worker_range in local.worker_cidr_ranges : (
            gateway_range.start > worker_range.end
            || worker_range.start > gateway_range.end
          )
        ]
      ]))
      error_message = "Gateway and worker VPC CIDRs must not overlap."
    }

    precondition {
      condition = (
        var.worker_domain == trimsuffix(var.route53_zone_name, ".")
        || endswith(var.worker_domain, ".${trimsuffix(var.route53_zone_name, ".")}")
      )
      error_message = "worker_domain must be inside route53_zone_name."
    }

    precondition {
      condition     = data.aws_subnet.worker_instance.vpc_id == var.worker_vpc_id
      error_message = "worker_instance_id is not in worker_vpc_id."
    }

    precondition {
      condition     = contains(data.aws_instance.worker.vpc_security_group_ids, var.worker_instance_security_group_id)
      error_message = "worker_instance_security_group_id is not attached to worker_instance_id."
    }

    precondition {
      condition = alltrue([
        for subnet in data.aws_subnet.gateway : subnet.vpc_id == var.gateway_vpc_id
      ])
      error_message = "Every gateway_subnet_id must belong to gateway_vpc_id."
    }

    precondition {
      condition = alltrue([
        for subnet in data.aws_subnet.worker : subnet.vpc_id == var.worker_vpc_id
      ])
      error_message = "Every worker_subnet_id must belong to worker_vpc_id."
    }

    precondition {
      condition = alltrue([
        for subnet_ids in values(local.worker_nlb_subnet_ids) :
        length(distinct([
          for subnet_id in subnet_ids :
          data.aws_subnet.worker[subnet_id].availability_zone
        ])) == length(subnet_ids)
      ])
      error_message = "Each worker's effective subnet IDs must contain at most one subnet per availability zone."
    }

    precondition {
      condition = alltrue([
        for subnet_ids in values(local.worker_nlb_subnet_ids) :
        contains(
          [
            for subnet_id in subnet_ids :
            data.aws_subnet.worker[subnet_id].availability_zone
          ],
          data.aws_subnet.worker_instance.availability_zone,
        )
      ])
      error_message = "Each worker's effective subnet IDs must include the GPU instance availability zone."
    }

    precondition {
      condition = alltrue([
        for route_table in data.aws_route_table.gateway : route_table.vpc_id == var.gateway_vpc_id
      ])
      error_message = "Every effective gateway subnet route table must belong to gateway_vpc_id."
    }

    precondition {
      condition = alltrue([
        for route_table in data.aws_route_table.worker : route_table.vpc_id == var.worker_vpc_id
      ])
      error_message = "Every effective worker subnet route table must belong to worker_vpc_id."
    }

    precondition {
      condition = alltrue([
        for name in keys(var.workers) :
        length(local.worker_nlb_names[name]) <= 32
        && length(local.worker_target_group_names[name]) <= 32
      ])
      error_message = "Generated or explicit NLB and target-group names must fit the 32-character AWS limit."
    }

    precondition {
      condition = (
        var.node_port_min >= 30000
        && var.node_port_max <= 32767
        && var.node_port_min <= var.node_port_max
        && alltrue([
          for worker in values(var.workers) :
          worker.node_port >= var.node_port_min && worker.node_port <= var.node_port_max
        ])
      )
      error_message = "NodePort bounds must be ordered, within 30000-32767, and contain every configured worker port."
    }

    precondition {
      condition     = var.manage_vpc_routes || var.existing_vpc_peering_connection_id != null
      error_message = "manage_vpc_routes can be false only when existing_vpc_peering_connection_id is supplied."
    }

    precondition {
      condition     = var.manage_security_group_rules || var.existing_nlb_security_group_id != null
      error_message = "manage_security_group_rules can be false only when existing_nlb_security_group_id is supplied."
    }

    precondition {
      condition = var.existing_vpc_peering_connection_id == null ? true : (
        data.aws_vpc_peering_connection.existing[0].vpc_id == var.gateway_vpc_id
        && data.aws_vpc_peering_connection.existing[0].peer_vpc_id == var.worker_vpc_id
        && data.aws_vpc_peering_connection.existing[0].status == "active"
      )
      error_message = "The existing peering connection must be active from gateway_vpc_id to worker_vpc_id."
    }

    precondition {
      condition = var.existing_nlb_security_group_id == null ? true : (
        data.aws_security_group.existing_nlb[0].vpc_id == var.worker_vpc_id
      )
      error_message = "existing_nlb_security_group_id must belong to worker_vpc_id."
    }

    precondition {
      condition = var.certificate_arn == null ? true : (
        data.aws_acm_certificate.existing[0].arn == var.certificate_arn
      )
      error_message = "certificate_arn must be the most recent ISSUED certificate covering *.worker_domain in aws_region."
    }
  }
}
