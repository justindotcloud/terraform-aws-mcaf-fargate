locals {
  load_balancer = var.public_subnet_ids != null ? { create : true } : {}
  region        = var.region != null ? var.region : data.aws_region.current.name
}

data "aws_region" "current" {}

module "task_execution_role" {
  source                = "github.com/schubergphilis/terraform-aws-mcaf-role?ref=v0.1.3"
  name                  = "TaskExecutionRole-${var.name}"
  principal_type        = "Service"
  principal_identifiers = ["ecs-tasks.amazonaws.com"]
  role_policy           = var.role_policy
  tags                  = var.tags
}

resource "aws_iam_role_policy_attachment" "task_execution_role" {
  role       = module.task_execution_role.id
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_cloudwatch_log_group" "default" {
  name              = "/ecs/${var.name}"
  retention_in_days = 30
  tags              = var.tags
}

data "null_data_source" "environment" {
  count = length(var.environment)

  inputs = {
    name  = "${element(keys(var.environment), count.index)}"
    value = "${element(values(var.environment), count.index)}"
  }
}

data "null_data_source" "secrets" {
  count = length(var.secrets)

  inputs = {
    name      = "${element(keys(var.secrets), count.index)}"
    valueFrom = "${element(values(var.secrets), count.index)}"
  }
}

data "template_file" "definition" {
  template = file("${path.module}/templates/container_definition.tpl")

  vars = {
    name        = var.name
    image       = var.image
    port        = var.port
    cpu         = var.cpu
    memory      = var.memory
    log_group   = aws_cloudwatch_log_group.default.name
    environment = jsonencode(data.null_data_source.environment.*.outputs)
    secrets     = jsonencode(data.null_data_source.secrets.*.outputs)
    region      = local.region
  }
}

resource "aws_ecs_task_definition" "default" {
  family                   = var.name
  execution_role_arn       = module.task_execution_role.arn
  task_role_arn            = module.task_execution_role.arn
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.cpu
  memory                   = var.memory
  container_definitions    = data.template_file.definition.rendered
  tags                     = var.tags
}

resource "aws_security_group" "ecs" {
  name        = "${var.name}-ecs"
  description = "Allow access to and from the ECS cluster"
  vpc_id      = var.vpc_id
  tags        = var.tags

  dynamic ingress {
    for_each = local.load_balancer

    content {
      protocol        = "tcp"
      from_port       = var.port
      to_port         = var.port
      security_groups = var.protocol != "TCP" ? [aws_security_group.lb.0.id] : null
      cidr_blocks     = var.protocol == "TCP" ? var.cidr_blocks : null
    }
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    ignore_changes = [description]
  }
}

resource "aws_ecs_cluster" "default" {
  name = var.name
  tags = var.tags
}

resource "aws_ecs_service" "default" {
  name            = var.name
  cluster         = aws_ecs_cluster.default.id
  task_definition = aws_ecs_task_definition.default.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    security_groups  = [aws_security_group.ecs.id]
    subnets          = var.private_subnet_ids
    assign_public_ip = var.public_ip
  }

  dynamic load_balancer {
    for_each = local.load_balancer

    content {
      target_group_arn = aws_lb_target_group.default.0.id
      container_name   = "app-${var.name}"
      container_port   = var.port
    }
  }
}
