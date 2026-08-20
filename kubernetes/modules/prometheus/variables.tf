variable "namespace" {
  description = "Kubernetes namespace for Prometheus"
  type        = string
  default     = "monitoring"
  nullable    = false
}

variable "create_namespace" {
  description = "Whether to create the namespace"
  type        = bool
  default     = true
  nullable    = false
}

variable "chart_version" {
  description = "Version of the Prometheus helm chart"
  type        = string
  default     = "28.0.0"
  nullable    = false
}

variable "install_timeout" {
  description = "Timeout for installing the Prometheus helm chart, in seconds"
  type        = number
  default     = 600
  nullable    = false
}

variable "kube_state_metrics_image" {
  description = "Override registry/repository/tag for the kube-state-metrics subchart image, for environments where registry.k8s.io egress is blocked (e.g. mcr.microsoft.com/oss/v2/kubernetes/kube-state-metrics mirror on Azure). Null uses the chart's default."
  type = object({
    registry   = string
    repository = string
    tag        = string
  })
  default = null
}

variable "storage_size" {
  description = "Storage size for Prometheus server persistent volume"
  type        = string
  default     = "50Gi"
  nullable    = false
}

variable "storage_class" {
  description = "Storage class for Prometheus server persistent volume"
  type        = string
  nullable    = false
}
variable "retention_days" {
  description = "Number of days to retain Prometheus data"
  type        = number
  default     = 15
  nullable    = false
}

variable "node_selector" {
  description = "Node selector for Prometheus pods"
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "tolerations" {
  description = "Tolerations for Prometheus pods"
  type = list(object({
    key      = string
    value    = optional(string)
    operator = optional(string, "Equal")
    effect   = string
  }))
  default  = []
  nullable = false
}

variable "server_resources" {
  description = "Resource requests and limits for Prometheus server"
  type = object({
    requests = optional(object({
      cpu    = optional(string, "500m")
      memory = optional(string, "512Mi")
    }))
    limits = optional(object({
      cpu    = optional(string, "1000m")
      memory = optional(string, "1Gi")
    }))
  })
  default = {
    requests = {}
    limits   = {}
  }
  nullable = false
}
