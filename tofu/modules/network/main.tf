data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "zone-type"
    values = ["availability-zone"]
  }
}

locals {
  availability_zones = slice(
    sort(data.aws_availability_zones.available.names),
    0,
    var.availability_zone_count,
  )
  zones = {
    for index, zone in local.availability_zones : zone => {
      index        = index
      public_cidr  = cidrsubnet(var.vpc_cidr, 4, index)
      private_cidr = cidrsubnet(var.vpc_cidr, 4, index + 8)
    }
  }
  common_tags = merge(
    {
      Environment = var.environment
      VPC         = var.vpc_name
    },
    var.tags,
  )
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, { Name = var.vpc_name })

  lifecycle {
    precondition {
      condition     = length(data.aws_availability_zones.available.names) >= var.availability_zone_count
      error_message = "The selected region does not have enough available standard Availability Zones."
    }
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "${var.vpc_name}-igw" })
}

resource "aws_subnet" "public" {
  for_each = local.zones

  availability_zone       = each.key
  cidr_block              = each.value.public_cidr
  map_public_ip_on_launch = true
  vpc_id                  = aws_vpc.this.id

  tags = merge(local.common_tags, {
    Name = "${var.vpc_name}-public-${each.key}"
    Type = "Public"
  })
}

resource "aws_subnet" "private" {
  for_each = local.zones

  availability_zone       = each.key
  cidr_block              = each.value.private_cidr
  map_public_ip_on_launch = false
  vpc_id                  = aws_vpc.this.id

  tags = merge(local.common_tags, {
    Name = "${var.vpc_name}-private-${each.key}"
    Type = "Private"
  })
}

resource "aws_eip" "nat" {
  for_each = var.enable_nat_gateways ? local.zones : {}

  domain = "vpc"

  tags = merge(local.common_tags, { Name = "${var.vpc_name}-nat-${each.key}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  for_each = var.enable_nat_gateways ? local.zones : {}

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id

  tags = merge(local.common_tags, { Name = "${var.vpc_name}-nat-${each.key}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "${var.vpc_name}-public-rt" })
}

resource "aws_route" "public_internet" {
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
  route_table_id         = aws_route_table.public.id
}

resource "aws_route_table_association" "public" {
  for_each = local.zones

  route_table_id = aws_route_table.public.id
  subnet_id      = aws_subnet.public[each.key].id
}

resource "aws_route_table" "private" {
  for_each = local.zones

  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "${var.vpc_name}-private-${each.key}-rt" })
}

resource "aws_route" "private_internet" {
  for_each = var.enable_nat_gateways ? local.zones : {}

  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[each.key].id
  route_table_id         = aws_route_table.private[each.key].id
}

resource "aws_route_table_association" "private" {
  for_each = local.zones

  route_table_id = aws_route_table.private[each.key].id
  subnet_id      = aws_subnet.private[each.key].id
}

resource "aws_security_group" "web" {
  name_prefix            = "${var.vpc_name}-web-"
  description            = "Public HTTP and HTTPS access for ${var.vpc_name}"
  revoke_rules_on_delete = true
  vpc_id                 = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "${var.vpc_name}-web-sg" })
}

resource "aws_security_group" "controller" {
  name_prefix            = "${var.vpc_name}-controller-"
  description            = "Coolify controller tier for ${var.vpc_name}"
  revoke_rules_on_delete = true
  vpc_id                 = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "${var.vpc_name}-controller-sg" })
}

resource "aws_security_group" "application" {
  name_prefix            = "${var.vpc_name}-application-"
  description            = "Coolify worker application tier for ${var.vpc_name}"
  revoke_rules_on_delete = true
  vpc_id                 = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "${var.vpc_name}-application-sg" })
}

resource "aws_security_group" "database" {
  name_prefix            = "${var.vpc_name}-database-"
  description            = "Optional database tier for ${var.vpc_name}"
  revoke_rules_on_delete = true
  vpc_id                 = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "${var.vpc_name}-database-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "web" {
  for_each = {
    for rule in setproduct(var.allowed_web_cidrs, [80, 443]) :
    "${rule[0]}:${rule[1]}" => rule
  }

  cidr_ipv4         = each.value[0]
  description       = each.value[1] == 80 ? "Public HTTP" : "Public HTTPS"
  from_port         = each.value[1]
  ip_protocol       = "tcp"
  security_group_id = aws_security_group.web.id
  to_port           = each.value[1]
}

resource "aws_vpc_security_group_ingress_rule" "controller_nebula" {
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Nebula lighthouse discovery and relay"
  from_port         = var.nebula_udp_port
  ip_protocol       = "udp"
  security_group_id = aws_security_group.controller.id
  to_port           = var.nebula_udp_port
}

resource "aws_vpc_security_group_ingress_rule" "database_postgresql" {
  description                  = "PostgreSQL from the application tier"
  from_port                    = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.application.id
  security_group_id            = aws_security_group.database.id
  to_port                      = 5432
}

resource "aws_vpc_security_group_ingress_rule" "database_mysql" {
  description                  = "MySQL from the application tier"
  from_port                    = 3306
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.application.id
  security_group_id            = aws_security_group.database.id
  to_port                      = 3306
}

resource "aws_vpc_security_group_egress_rule" "controller_tcp" {
  for_each = {
    for port in var.controller_outbound_tcp_ports : tostring(port) => port
  }

  cidr_ipv4         = "0.0.0.0/0"
  description       = "Controller outbound TCP ${each.value}"
  from_port         = each.value
  ip_protocol       = "tcp"
  security_group_id = aws_security_group.controller.id
  to_port           = each.value
}

resource "aws_vpc_security_group_egress_rule" "application_tcp" {
  for_each = {
    for port in var.application_outbound_tcp_ports : tostring(port) => port
  }

  cidr_ipv4         = "0.0.0.0/0"
  description       = "Application outbound TCP ${each.value}"
  from_port         = each.value
  ip_protocol       = "tcp"
  security_group_id = aws_security_group.application.id
  to_port           = each.value
}

resource "aws_vpc_security_group_egress_rule" "controller_nebula" {
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Nebula overlay traffic"
  from_port         = var.nebula_udp_port
  ip_protocol       = "udp"
  security_group_id = aws_security_group.controller.id
  to_port           = var.nebula_udp_port
}

resource "aws_vpc_security_group_egress_rule" "application_nebula" {
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Nebula overlay traffic"
  from_port         = var.nebula_udp_port
  ip_protocol       = "udp"
  security_group_id = aws_security_group.application.id
  to_port           = var.nebula_udp_port
}

data "aws_iam_policy_document" "flow_logs_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "${var.vpc_name}-flow-logs-role"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume_role.json
  description        = "Delivers ${var.vpc_name} VPC Flow Logs to CloudWatch Logs"

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/vpc/${var.vpc_name}/flow-logs"
  retention_in_days = var.flow_log_retention_days

  tags = local.common_tags
}

data "aws_iam_policy_document" "flow_logs" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.flow_logs.arn}:*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "${var.vpc_name}-flow-logs-policy"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs.json
}

resource "aws_flow_log" "this" {
  iam_role_arn             = aws_iam_role.flow_logs.arn
  log_destination          = aws_cloudwatch_log_group.flow_logs.arn
  log_destination_type     = "cloud-watch-logs"
  max_aggregation_interval = 60
  # Migration bridge: AWS cannot update a flow log's traffic type. Keep the
  # state-owned ALL log unchanged until the REJECT log below is active, then
  # remove this resource in the final cleanup change.
  traffic_type = "ALL"
  vpc_id       = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "${var.vpc_name}-flow-log" })

  depends_on = [aws_iam_role_policy.flow_logs]
}

resource "aws_flow_log" "rejected" {
  iam_role_arn             = aws_iam_role.flow_logs.arn
  log_destination          = aws_cloudwatch_log_group.flow_logs.arn
  log_destination_type     = "cloud-watch-logs"
  max_aggregation_interval = 60
  traffic_type             = var.flow_log_traffic_type
  vpc_id                   = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "${var.vpc_name}-rejected-flow-log" })

  depends_on = [aws_iam_role_policy.flow_logs]
}
