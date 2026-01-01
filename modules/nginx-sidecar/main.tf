# modules/nginx-sidecar
#
# Produces the nginx container definition that modules/ecs-service drops into its task
# definition, plus the S3 object holding the rendered config.
#
# Why a sidecar at all, given the ALB already terminates TLS and routes: because the ALB is
# not the only way into a task. Service-to-service traffic goes over service discovery
# straight to the ENI, and the ^/internal/ deny has to exist on that path too. The ALB rule
# and this config are two halves of the same policy (interfaces.md §6.3), and for five
# months the ALB half was inert while this half was the only thing working. See PAY-1811.
#
# The config is not baked into an image. It is written to S3 by terraform and pulled at task
# start, so an nginx change is an `apply` and a service restart rather than a build. That was
# the right call in month 2 and it is a slightly odd one now — service connect would replace
# the whole thing. It is on the list and it is not urgent.

terraform {
  required_version = ">= 1.7.0, < 1.8.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
  }
}

module "names" {
  source = "../naming"

  service     = var.service
  environment = var.environment
  component   = "sidecar"
  extra_tags  = var.extra_tags
}

data "aws_caller_identity" "current" {}

locals {
  config_bucket = "payzeno-${var.environment}-service-config-${data.aws_caller_identity.current.account_id}"

  # The upstream is the app container on the loopback inside the task. awsvpc networking
  # means both containers share a network namespace, so 127.0.0.1 is correct and a service
  # name here would be wrong.
  upstream_block = <<-NGINX
    upstream ${replace(module.names.short_service, "-", "_")}_app {
      server 127.0.0.1:${var.upstream_port} max_fails=3 fail_timeout=10s;
      keepalive 32;
    }
  NGINX

  # One server block per listener port. 80 is the ALB-facing one and carries the deny; 8081
  # is the internal listener and is the one that is *allowed* to serve /internal/v1/.
  server_blocks = join("\n", [
    for port in var.listener_ports : <<-NGINX
      server {
        listen ${port};
        server_name _;

        client_max_body_size ${var.client_max_body_size};

        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Request-Id      $request_id;

        location = /healthz {
          proxy_pass http://${replace(module.names.short_service, "-", "_")}_app;
          access_log off;
        }

        ${port == 8081 ? "" : "location ~ ^/internal/ { deny all; return 404; }"}

        location / {
          proxy_pass http://${replace(module.names.short_service, "-", "_")}_app;
          proxy_read_timeout ${var.proxy_read_timeout_seconds}s;
        }
      }
    NGINX
  ])

  rendered_config = join("\n", [local.upstream_block, local.server_blocks])
}

resource "aws_s3_object" "nginx_conf" {
  bucket = local.config_bucket
  key    = var.config_key

  content      = local.rendered_config
  content_type = "text/plain"

  # Without this the object is replaced on every apply whose rendered content differs by a
  # byte of whitespace, and every replacement is a silent config change that only takes
  # effect on the next task start. The etag makes the diff honest.
  etag = md5(local.rendered_config)

  tags = merge(module.names.tags, {
    Name = var.config_key
  })
}

locals {
  # The container definition itself. modules/ecs-service concatenates this onto its own
  # app container and jsonencodes the pair — this is a HCL object, not a JSON string, so
  # that the caller can inspect it rather than parse it.
  container_definition = {
    name      = "nginx"
    image     = var.nginx_image
    essential = true

    portMappings = [
      for port in var.listener_ports : {
        containerPort = port
        hostPort      = port
        protocol      = "tcp"
        name          = port == 8081 ? "internal" : "public"
      }
    ]

    # The app container has to be up before nginx starts proxying to it, or the first
    # health check races the first boot and the target group flaps.
    dependsOn = [{
      containerName = var.service
      condition     = "HEALTHY"
    }]

    environment = [
      { name = "PAYZENO_CONFIG_URI", value = "s3://${local.config_bucket}/${var.config_key}" },
      { name = "PAYZENO_UPSTREAM_PORT", value = tostring(var.upstream_port) },
    ]

    entryPoint = ["/bin/sh", "-c"]
    command = [
      join(" && ", [
        "aws s3 cp s3://${local.config_bucket}/${var.config_key} /etc/nginx/conf.d/default.conf",
        "nginx -t",
        "exec nginx -g 'daemon off;'",
      ])
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = module.names.log_group_name
        "awslogs-region"        = data.aws_region.current.name
        "awslogs-stream-prefix" = "nginx"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "curl -fsS http://localhost:${var.listener_ports[0]}/healthz || exit 1"]
      interval    = 15
      timeout     = 5
      retries     = 3
      startPeriod = 30
    }
  }
}

data "aws_region" "current" {}

output "container_definition" {
  description = "The nginx container definition object, concatenated into the task definition by modules/ecs-service."
  value       = local.container_definition
}

output "config_s3_uri" {
  description = "s3:// URI of the rendered nginx config this task pulls at start."
  value       = "s3://${local.config_bucket}/${aws_s3_object.nginx_conf.key}"
}

output "config_bucket_arn" {
  description = "ARN of the shared service-config bucket. The execution role needs s3:GetObject under this module's prefix."
  value       = "arn:aws:s3:::${local.config_bucket}"
}

output "rendered_config" {
  description = "The rendered nginx config. Exposed so `terraform console` can show it without a round trip to S3 — nginx -t in CI runs against nginx/ in the repo, not against this."
  value       = local.rendered_config
}
