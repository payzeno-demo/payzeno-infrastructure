# modules/nginx-sidecar — inputs.
#
# Split out even though this module is borderline on the 60-line rule. Harmless; see
# CONTRIBUTING.md §4 for the honest state of that convention.

variable "service" {
  description = "The service this sidecar fronts. Must be the same string modules/ecs-service passed to naming, because the container's dependsOn names it."
  type        = string
}

variable "environment" {
  description = "production | staging."
  type        = string
}

variable "upstream_port" {
  description = "Port the app container listens on inside the task. nginx proxies to 127.0.0.1 on this port — awsvpc means both containers share a network namespace."
  type        = number

  validation {
    condition     = contains([8080, 8000, 8090, 8099], var.upstream_port)
    error_message = "PAYZENO_INFRA_INVALID_INPUT: upstream_port must be one of the four contracted application ports (8080, 8000, 8090, 8099)."
  }
}

variable "config_key" {
  description = "S3 key for the rendered nginx config, under the shared service-config bucket. modules/ecs-service passes \"<naming id>/nginx.conf\" and the execution role's s3:GetObject is scoped to that prefix."
  type        = string

  validation {
    condition     = endswith(var.config_key, "/nginx.conf")
    error_message = "PAYZENO_INFRA_INVALID_INPUT: config_key must end in /nginx.conf — the execution-role policy in modules/ecs-service is scoped on the prefix before it."
  }
}

variable "listener_ports" {
  description = <<-EOT
    Ports nginx listens on inside the task. Almost always [80, 8081]:

      80    ALB-facing. Carries the `location ~ ^/internal/ { deny all; return 404; }` rule,
            which mirrors module.rule_api_internal_deny on the ALB.
      8081  internal-network listener. This is the one that is ALLOWED to serve
            /internal/v1/*, and it is only reachable from 10.0.0.0/8 (the security group
            rule is in modules/ecs-service/main.tf).

    The deny is emitted on every port EXCEPT 8081. If you add a port, that is the behaviour
    you get, and it is the behaviour you want.
  EOT
  type        = list(number)
  default     = [80, 8081]

  validation {
    condition     = length(var.listener_ports) > 0 && length(var.listener_ports) <= 4
    error_message = "PAYZENO_INFRA_INVALID_INPUT: between one and four listener ports."
  }

  validation {
    condition = alltrue([
      for p in var.listener_ports : !contains([8080, 8000, 8090, 8099], p)
    ])
    error_message = "PAYZENO_INFRA_INVALID_INPUT: a listener port collides with an application port. nginx and the app share a network namespace; two listeners on 8080 is a task that will not start and an error message that does not say why."
  }
}

variable "nginx_image" {
  description = "Sidecar image. Pinned, and bumped deliberately — nginx minor versions have changed proxy_pass buffering defaults on us before."
  type        = string
  default     = "public.ecr.aws/payzeno/nginx-awscli:1.25.4-alpine"
}

variable "proxy_read_timeout_seconds" {
  description = "Upstream read timeout. 60s is right for HTTP; the WebSocket route needs 3600 and gets it from nginx/payzeno-api.conf on the ingress tier, not from here."
  type        = number
  default     = 60

  validation {
    condition     = var.proxy_read_timeout_seconds >= 5 && var.proxy_read_timeout_seconds <= 3600
    error_message = "PAYZENO_INFRA_INVALID_INPUT: proxy_read_timeout_seconds must be between 5 and 3600."
  }
}

variable "client_max_body_size" {
  description = "Largest accepted request body. Dispute evidence uploads are the big ones; everything else is under 100k. Tightened from 50m in the PCI wave."
  type        = string
  default     = "10m"
}

variable "extra_tags" {
  description = "Merged under the standard tag set."
  type        = map(string)
  default     = {}
}
