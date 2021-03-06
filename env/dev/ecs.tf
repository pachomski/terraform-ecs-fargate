/**
 * Elastic Container Service (ecs)
 * This component is required to create the Fargate ECS service. It will create a Fargate cluster
 * based on the application name and enironment. It will create a "Task Definition", which is required
 * to run a Docker container, https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_definitions.html.
 * Next it creates a ECS Service, https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs_services.html
 * It attaches the Load Balancer created in `lb.tf` to the service, and sets up the networking required.
 * It also creates a role with the correct permissions. And lastly, ensures that logs are captured in CloudWatch.
 *
 * When building for the first time, it will install a "default backend", which is a simple web service that just
 * responds with a HTTP 200 OK. It's important to uncomment the lines noted below after you have successfully
 * migrated the real application containers to the task definition.
 */

resource "aws_ecs_cluster" "app" {
  name = "${var.app}-${var.environment}"
}

resource "aws_ecs_task_definition" "app" {
  family                   = "${var.app}-${var.environment}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "${var.cpu}"
  memory                   = "${var.memory}"
  execution_role_arn       = "${aws_iam_role.ecsTaskExecutionRole.arn}"

  # defined in role.tf
  task_role_arn = "${aws_iam_role.app_role.arn}"

  container_definitions = <<DEFINITION
[
  {
    "name": "${var.container_name}",
    "image": "quay.io/turner/turner-defaultbackend:0.2.0",
    "essential": true,
    "portMappings": [
      {
        "protocol": "tcp",
        "containerPort": ${var.container_port}
      }
    ],
    "environment": [
      {
        "name": "PORT",
        "value": "${var.container_port}"
      },
      {
        "name": "HEALTHCHECK",
        "value": "${var.health_check}"
      },
      {
        "name": "ENABLE_LOGGING",
        "value": "false"
      },
      {
        "name": "PRODUCT",
        "value": "${var.app}"
      },
      {
        "name": "ENVIRONMENT",
        "value": "${var.environment}"
      }
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/fargate/service/${var.app}-${var.environment}",
        "awslogs-region": "us-east-1",
        "awslogs-stream-prefix": "ecs"
      }
    }
  }
]
DEFINITION

  # # uncomment after first app deployment
  # lifecycle {
  #   ignore_changes = ["container_definitions"]
  # }
}

resource "aws_ecs_service" "app" {
  name            = "${var.app}-${var.environment}"
  cluster         = "${aws_ecs_cluster.app.id}"
  launch_type     = "FARGATE"
  task_definition = "${aws_ecs_task_definition.app.arn}"
  desired_count   = "${var.replicas}"

  network_configuration {
    security_groups = ["${aws_security_group.nsg_task.id}"]
    subnets         = ["${split(",", var.private_subnets)}"]
  }

  load_balancer {
    target_group_arn = "${aws_alb_target_group.main.id}"
    container_name   = "${var.container_name}"
    container_port   = "${var.container_port}"
  }

  # workaround for https://github.com/hashicorp/terraform/issues/12634
  depends_on = [
    "aws_alb_listener.http",
  ]

  # # uncomment after first app deployment
  # lifecycle {
  #   ignore_changes = ["task_definition"]
  # }
}

# https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_execution_IAM_role.html
resource "aws_iam_role" "ecsTaskExecutionRole" {
  name               = "${var.app}-${var.environment}-ecs"
  assume_role_policy = "${data.aws_iam_policy_document.assume_role_policy.json}"
}

data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "ecsTaskExecutionRole_policy" {
  role       = "${aws_iam_role.ecsTaskExecutionRole.name}"
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_cloudwatch_log_group" "logs" {
  name              = "/fargate/service/${var.app}-${var.environment}"
  retention_in_days = "14"
  tags              = "${var.tags}"
}
