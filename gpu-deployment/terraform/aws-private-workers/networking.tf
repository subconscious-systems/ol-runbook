locals {
  common_tags = merge(
    {
      ManagedBy = "terraform"
      Component = "private-sglang-workers"
    },
    var.tags,
  )

  gateway_vpc_cidrs = toset([
    for association in data.aws_vpc.gateway.cidr_block_associations :
    association.cidr_block if association.state == "associated"
  ])
  worker_vpc_cidrs = toset([
    for association in data.aws_vpc.worker.cidr_block_associations :
    association.cidr_block if association.state == "associated"
  ])

  worker_route_subnet_ids = setunion(
    var.worker_subnet_ids,
    toset([data.aws_instance.worker.subnet_id]),
  )
  gateway_main_route_table_id = one(flatten([
    for route_table in data.aws_route_table.gateway : [
      for association in route_table.associations :
      route_table.id if association.main
    ]
  ]))
  worker_main_route_table_id = one(flatten([
    for route_table in data.aws_route_table.worker : [
      for association in route_table.associations :
      route_table.id if association.main
    ]
  ]))
  gateway_explicit_subnet_route_tables = merge([
    for route_table in data.aws_route_table.gateway : {
      for association in route_table.associations :
      association.subnet_id => route_table.id if association.subnet_id != ""
    }
  ]...)
  worker_explicit_subnet_route_tables = merge([
    for route_table in data.aws_route_table.worker : {
      for association in route_table.associations :
      association.subnet_id => route_table.id if association.subnet_id != ""
    }
  ]...)
  gateway_route_table_ids = toset([
    for subnet_id in var.gateway_subnet_ids :
    lookup(local.gateway_explicit_subnet_route_tables, subnet_id, local.gateway_main_route_table_id)
  ])
  worker_route_table_ids = toset([
    for subnet_id in local.worker_route_subnet_ids :
    lookup(local.worker_explicit_subnet_route_tables, subnet_id, local.worker_main_route_table_id)
  ])

  gateway_cidr_ranges = {
    for cidr in local.gateway_vpc_cidrs :
    cidr => {
      start = sum([
        for index, octet in split(".", cidrhost(cidr, 0)) :
        tonumber(octet) * element([16777216, 65536, 256, 1], index)
      ])
      end = sum([
        for index, octet in split(".", cidrhost(cidr, -1)) :
        tonumber(octet) * element([16777216, 65536, 256, 1], index)
      ])
    }
  }
  worker_cidr_ranges = {
    for cidr in local.worker_vpc_cidrs :
    cidr => {
      start = sum([
        for index, octet in split(".", cidrhost(cidr, 0)) :
        tonumber(octet) * element([16777216, 65536, 256, 1], index)
      ])
      end = sum([
        for index, octet in split(".", cidrhost(cidr, -1)) :
        tonumber(octet) * element([16777216, 65536, 256, 1], index)
      ])
    }
  }

  gateway_to_worker_routes = {
    for pair in setproduct(local.gateway_route_table_ids, local.worker_vpc_cidrs) :
    "${pair[0]}|${pair[1]}" => {
      route_table_id = pair[0]
      cidr_block     = pair[1]
    }
  }
  worker_to_gateway_routes = {
    for pair in setproduct(local.worker_route_table_ids, local.gateway_vpc_cidrs) :
    "${pair[0]}|${pair[1]}" => {
      route_table_id = pair[0]
      cidr_block     = pair[1]
    }
  }

  vpc_peering_connection_id = var.existing_vpc_peering_connection_id != null ? (
    var.existing_vpc_peering_connection_id
  ) : aws_vpc_peering_connection.gateway_to_workers[0].id

  nlb_security_group_id = var.existing_nlb_security_group_id != null ? (
    var.existing_nlb_security_group_id
  ) : aws_security_group.worker_nlbs[0].id

  worker_resource_names = {
    for name in keys(var.workers) :
    name => join("-", compact([var.name_prefix, name]))
  }

  worker_target_group_names = {
    for name, worker in var.workers :
    name => coalesce(
      worker.target_group_name,
      "${local.worker_resource_names[name]}-${substr(sha1(join(":", [var.worker_vpc_id, tostring(worker.node_port)])), 0, 6)}",
    )
  }

  worker_nlb_names = {
    for name, worker in var.workers :
    name => coalesce(
      worker.nlb_name,
      join("-", compact([local.worker_resource_names[name], "NLB"])),
    )
  }
}

resource "aws_vpc_peering_connection" "gateway_to_workers" {
  count = var.existing_vpc_peering_connection_id == null ? 1 : 0

  vpc_id      = var.gateway_vpc_id
  peer_vpc_id = var.worker_vpc_id
  auto_accept = true

  tags = {
    Name = join("-", compact([var.name_prefix, "gateway-workers"]))
  }

  depends_on = [terraform_data.validated_inputs]
}

resource "aws_vpc_peering_connection_options" "gateway_to_workers" {
  count = var.existing_vpc_peering_connection_id == null ? 1 : 0

  vpc_peering_connection_id = aws_vpc_peering_connection.gateway_to_workers[0].id

  requester {
    allow_remote_vpc_dns_resolution = true
  }

  accepter {
    allow_remote_vpc_dns_resolution = true
  }
}

resource "aws_route" "gateway_to_workers" {
  for_each = var.manage_vpc_routes ? local.gateway_to_worker_routes : {}

  route_table_id            = each.value.route_table_id
  destination_cidr_block    = each.value.cidr_block
  vpc_peering_connection_id = local.vpc_peering_connection_id

  depends_on = [terraform_data.validated_inputs]
}

resource "aws_route" "workers_to_gateway" {
  for_each = var.manage_vpc_routes ? local.worker_to_gateway_routes : {}

  route_table_id            = each.value.route_table_id
  destination_cidr_block    = each.value.cidr_block
  vpc_peering_connection_id = local.vpc_peering_connection_id

  depends_on = [terraform_data.validated_inputs]
}

resource "aws_security_group" "worker_nlbs" {
  count = var.existing_nlb_security_group_id == null ? 1 : 0

  name        = var.nlb_security_group_name
  description = "Private SGLang NLBs reachable from the API gateway VPC"
  vpc_id      = var.worker_vpc_id

  revoke_rules_on_delete = true

  tags = {
    Name = var.nlb_security_group_name
  }

  depends_on = [terraform_data.validated_inputs]
}

resource "aws_vpc_security_group_ingress_rule" "gateway_https_to_nlbs" {
  for_each = var.manage_security_group_rules ? local.gateway_vpc_cidrs : toset([])

  security_group_id = local.nlb_security_group_id
  description       = "TLS from the API gateway VPC"

  cidr_ipv4   = each.value
  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443
}

resource "aws_vpc_security_group_egress_rule" "nlbs_to_worker_nodeports" {
  count = var.manage_security_group_rules ? 1 : 0

  security_group_id = local.nlb_security_group_id
  description       = "Worker traffic and health checks"

  referenced_security_group_id = var.worker_instance_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = var.node_port_min
  to_port                      = var.node_port_max
}

resource "aws_vpc_security_group_ingress_rule" "nlbs_to_worker_nodeports" {
  count = var.manage_security_group_rules ? 1 : 0

  security_group_id = var.worker_instance_security_group_id
  description       = "SGLang NodePorts from private worker NLBs"

  referenced_security_group_id = local.nlb_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = var.node_port_min
  to_port                      = var.node_port_max
}
