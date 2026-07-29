# Custom CoreDNS deployment for all cloud providers, because in some cloud providers, the default CoreDNS doesn't support overriding the default configuration including cache.
# Azure reference: https://github.com/Azure/AKS/issues/3661
locals {
  namespace = "kube-system"
  labels = {
    "k8s-app"        = "kube-dns"
    "provisioned-by" = "materialize"
  }

  # Corefile with TTL 0 first in the kubernetes plugin block (required for correct parsing)
  corefile = <<-EOF
    .:53 {
        errors
        health {
            lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
            ttl 0
            pods insecure
            fallthrough in-addr.arpa ip6.arpa
        }
        prometheus :9153
        forward . /etc/resolv.conf {
            max_concurrent 1000
        }
        cache 30 {
            disable denial cluster.local
            disable success cluster.local
        }
        loop
        reload
        loadbalance
    }
  EOF
}


# ServiceAccount for CoreDNS
resource "kubernetes_service_account" "coredns" {
  count = var.create_coredns_service_account ? 1 : 0
  metadata {
    name      = "coredns"
    namespace = local.namespace
  }
}

# ClusterRole for CoreDNS
resource "kubernetes_cluster_role" "coredns" {
  count = var.create_coredns_service_account ? 1 : 0
  metadata {
    name = "system:coredns"
  }

  rule {
    api_groups = [""]
    resources  = ["endpoints", "services", "pods", "namespaces"]
    verbs      = ["list", "watch"]
  }

  rule {
    api_groups = ["discovery.k8s.io"]
    resources  = ["endpointslices"]
    verbs      = ["list", "watch"]
  }
}

# ClusterRoleBinding for CoreDNS
resource "kubernetes_cluster_role_binding" "coredns" {
  count = var.create_coredns_service_account ? 1 : 0
  metadata {
    name = "system:coredns"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.coredns[0].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.coredns[0].metadata[0].name
    namespace = local.namespace
  }
}

# ConfigMap with Corefile
resource "kubernetes_config_map" "coredns" {
  metadata {
    name      = "coredns-user-managed"
    namespace = local.namespace
  }

  data = {
    Corefile = local.corefile
  }
}

# Custom CoreDNS Deployment
resource "kubernetes_deployment" "coredns" {
  metadata {
    name      = "coredns-custom"
    namespace = local.namespace
    labels = merge(local.labels, {
      "kubernetes.io/name" = "CoreDNS"
    })
  }

  spec {
    replicas = var.replicas

    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = "1"
      }
    }

    selector {
      match_labels = local.labels
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        priority_class_name  = "system-cluster-critical"
        service_account_name = "coredns"

        toleration {
          key      = "CriticalAddonsOnly"
          operator = "Exists"
        }

        node_selector = var.node_selector

        affinity {
          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 100
              pod_affinity_term {
                label_selector {
                  match_expressions {
                    key      = "k8s-app"
                    operator = "In"
                    values   = ["kube-dns"]
                  }
                }
                topology_key = "kubernetes.io/hostname"
              }
            }
          }
        }

        container {
          name              = "coredns"
          image             = "coredns/coredns:${var.coredns_version}"
          image_pull_policy = "IfNotPresent"

          args = ["-conf", "/etc/coredns/Corefile"]

          resources {
            limits = {
              memory = var.memory_limit
            }
            requests = {
              cpu    = var.cpu_request
              memory = var.memory_request
            }
          }

          volume_mount {
            name       = "config-volume"
            mount_path = "/etc/coredns"
            read_only  = true
          }

          port {
            container_port = 53
            name           = "dns"
            protocol       = "UDP"
          }

          port {
            container_port = 53
            name           = "dns-tcp"
            protocol       = "TCP"
          }

          port {
            container_port = 9153
            name           = "metrics"
            protocol       = "TCP"
          }

          liveness_probe {
            http_get {
              path   = "/health"
              port   = 8080
              scheme = "HTTP"
            }
            initial_delay_seconds = 60
            timeout_seconds       = 5
            success_threshold     = 1
            failure_threshold     = 5
          }

          readiness_probe {
            http_get {
              path   = "/ready"
              port   = 8181
              scheme = "HTTP"
            }
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              add  = ["NET_BIND_SERVICE"]
              drop = ["all"]
            }
          }
        }

        dns_policy = "Default"

        volume {
          name = "config-volume"
          config_map {
            name = kubernetes_config_map.coredns.metadata[0].name
            items {
              key  = "Corefile"
              path = "Corefile"
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_config_map.coredns,
    terraform_data.scale_down_kube_dns,
    terraform_data.scale_down_kube_dns_autoscaler
  ]
}


# Scale down the default kube-dns deployment (and its autoscaler) so only
# the custom CoreDNS serves DNS.
#
# The kubeconfig is passed to the provisioner via `environment` and is never
# stored in the resource: terraform_data mirrors `input` into its
# non-sensitive `output` attribute, which would print the kubeconfig in
# cleartext in plan and destroy diffs.
#
# There is deliberately no destroy-time counterpart that scales kube-dns back
# up. Destroy-time provisioners can only reference `self`, so the kubeconfig
# would have to live in state, and the credentials captured there are
# almost always expired by the time a destroy runs. An operator removing only
# the CoreDNS module (without destroying the cluster) must scale kube-dns
# back up manually:
#   kubectl scale deployment <kube-dns deployment> -n kube-system --replicas=2
#   kubectl scale deployment <kube-dns autoscaler deployment> -n kube-system --replicas=1
#
# Terraform 1.16 adds a `store` block to terraform_data whose value can be
# marked sensitive (masked `sensitive_output` attribute, see
# https://github.com/hashicorp/terraform/pull/38298). Once 1.16 is an
# acceptable required_version floor, a destroy-time scale-up could be
# reintroduced by storing the kubeconfig there and reading
# `self.store.sensitive_output` — though the stored credentials would still
# usually be expired by destroy time.
# The scale-down scripts below are written to real files on disk (via the
# local provider) rather than passed inline through the local-exec
# provisioner's `command`. On Windows, passing a long multi-line heredoc
# through `interpreter = ["bash", "-c"]` is unreliable - the OS process-launch
# layer (and/or an MSYS2/Git-Bash or WSL relay in between bash and the real
# shell) can mangle or drop newlines and quoting in the inline command before
# bash ever sees it, corrupting the script. Writing the script to a file and
# invoking it with a short, single-argument command line (`bash "<path>"`)
# avoids all of that; only a single quoted path needs to survive the
# Windows/Unix argument boundary, not the entire script's syntax.
resource "local_file" "scale_down_kube_dns_autoscaler_script" {
  count           = var.disable_default_coredns_autoscaler ? 1 : 0
  filename        = "${path.root}/.terraform/tmp/coredns/scale_down_kube_dns_autoscaler.sh"
  file_permission = "0700"
  # replace() strips any \r\n that may have been introduced if this .tf file
  # is checked out with Windows-style (CRLF) line endings (e.g. git
  # core.autocrlf=true) - a stray \r attaches to the last token of each shell
  # line (e.g. "pipefail\r"), which bash parses as part of that token and
  # rejects, producing garbled-looking errors because the raw \r byte moves
  # the terminal cursor back to column 0 when the error message is printed.
  #
  # The kubeconfig/deployment/namespace values are baked directly into the
  # script as literal assignments (via Terraform interpolation) rather than
  # read from the local-exec `environment` block at runtime. On this host,
  # `bash` resolves through a relay (WSL launcher or similar) that does not
  # forward the parent process's environment variables into the shell that
  # actually executes the script, causing "unbound variable" errors even
  # though the provisioner's `environment` block sets them. Embedding the
  # values as part of the file content sidesteps that boundary entirely. The
  # kubeconfig is base64-encoded here (and decoded in the script) because it
  # is arbitrary multi-line YAML that may contain quotes/special characters
  # unsafe to splice directly into a double-quoted bash string.
  content = replace(<<-EOT
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG_DATA_B64="${base64encode(var.kubeconfig_data)}"
    DEPLOYMENT_NAME="${var.coredns_autoscaler_deployment_to_scale_down}"
    NAMESPACE="${local.namespace}"

    kubeconfig_file=$(mktemp)
    trap "rm -f '$${kubeconfig_file}'" EXIT
    echo "$${KUBECONFIG_DATA_B64}" | base64 --decode > "$${kubeconfig_file}"

    output=$(kubectl --kubeconfig="$${kubeconfig_file}" scale deployment "$${DEPLOYMENT_NAME}" -n "$${NAMESPACE}" --replicas=0 2>&1) || {
      if echo "$output" | grep -q "no objects passed to scale"; then
        echo "Deployment $${DEPLOYMENT_NAME} not found, skipping"
        exit 0
      fi
      echo "Error scaling down $${DEPLOYMENT_NAME} deployment: $output"
      exit 1
    }
    echo "Successfully scaled down $${DEPLOYMENT_NAME} to 0 replicas"
  EOT
  , "\r\n", "\n")
}

resource "local_file" "scale_down_kube_dns_script" {
  count           = var.disable_default_coredns ? 1 : 0
  filename        = "${path.root}/.terraform/tmp/coredns/scale_down_kube_dns.sh"
  file_permission = "0700"
  # See the comment on local_file.scale_down_kube_dns_autoscaler_script above
  # for why replace() is used to strip \r, and why the values are baked into
  # the script directly instead of read from the local-exec `environment`
  # block.
  content = replace(<<-EOT
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG_DATA_B64="${base64encode(var.kubeconfig_data)}"
    DEPLOYMENT_NAME="${var.coredns_deployment_to_scale_down}"
    NAMESPACE="${local.namespace}"

    kubeconfig_file=$(mktemp)
    trap "rm -f '$${kubeconfig_file}'" EXIT
    echo "$${KUBECONFIG_DATA_B64}" | base64 --decode > "$${kubeconfig_file}"

    output=$(kubectl --kubeconfig="$${kubeconfig_file}" scale deployment "$${DEPLOYMENT_NAME}" -n "$${NAMESPACE}" --replicas=0 2>&1) || {
      if echo "$output" | grep -q "no objects passed to scale"; then
        echo "Deployment $${DEPLOYMENT_NAME} not found, skipping"
        exit 0
      fi
      echo "Error scaling down $${DEPLOYMENT_NAME} deployment: $output"
      exit 1
    }
    echo "Successfully scaled down $${DEPLOYMENT_NAME} to 0 replicas"
  EOT
  , "\r\n", "\n")
}

resource "terraform_data" "scale_down_kube_dns_autoscaler" {
  count            = var.disable_default_coredns_autoscaler ? 1 : 0
  triggers_replace = [var.cluster_identifier, var.coredns_autoscaler_deployment_to_scale_down, local.namespace]

  # The script is written to a real file (instead of being passed inline as a
  # multi-line heredoc through `interpreter = ["bash", "-c"]`) because on
  # Windows, the OS process-launch layer (and/or an MSYS2/Git-Bash or WSL
  # relay in between) can mangle or drop newlines/quoting in long inline
  # commands, corrupting the script before bash ever sees it. Invoking a file
  # with a short, single-argument command line avoids that entirely.
  depends_on = [local_file.scale_down_kube_dns_autoscaler_script]

  provisioner "local-exec" {
    # interpreter = ["bash"] (no "-c") makes Terraform exec bash directly
    # with `command` as a single argv element, instead of routing it through
    # an intermediate shell (cmd /C on Windows, /bin/sh -c otherwise). That
    # intermediate shell/relay is what was re-quoting (and corrupting) the
    # path previously, so it must be avoided here too, not just for the
    # script contents.
    #
    # No `environment` block is used: on this host, `bash` resolves through
    # a relay that does not forward the parent process's environment
    # variables into the shell that runs the script (see the comment on
    # local_file.scale_down_kube_dns_autoscaler_script), so all inputs are
    # baked directly into the script file content instead.
    interpreter = ["bash"]
    when        = create
    on_failure  = fail
    command     = local_file.scale_down_kube_dns_autoscaler_script[0].filename
  }
}

resource "terraform_data" "scale_down_kube_dns" {
  count            = var.disable_default_coredns ? 1 : 0
  triggers_replace = [var.cluster_identifier, var.coredns_deployment_to_scale_down, local.namespace]

  # See the comment on local_file.scale_down_kube_dns_autoscaler_script above
  # for why this script is written to a file instead of passed inline.
  depends_on = [
    local_file.scale_down_kube_dns_script,
    terraform_data.scale_down_kube_dns_autoscaler,
  ]

  provisioner "local-exec" {
    # See the comment in scale_down_kube_dns_autoscaler above for why
    # interpreter = ["bash"] (with an unquoted path) is used, and why no
    # `environment` block is needed here.
    interpreter = ["bash"]
    when        = create
    on_failure  = fail
    command     = local_file.scale_down_kube_dns_script[0].filename
  }
}

module "hpa" {
  source = "../hpa"

  name        = "coredns-custom"
  namespace   = local.namespace
  target_name = kubernetes_deployment.coredns.metadata[0].name
  target_kind = "Deployment"

  min_replicas = var.hpa_min_replicas
  max_replicas = var.hpa_max_replicas

  cpu_target_utilization    = var.hpa_cpu_target_utilization
  memory_target_utilization = var.hpa_memory_target_utilization

  scale_up_stabilization_window = var.hpa_scale_up_stabilization_window
  scale_up_pods_per_period      = var.hpa_scale_up_pods_per_period
  scale_up_percent_per_period   = var.hpa_scale_up_percent_per_period

  scale_down_stabilization_window = var.hpa_scale_down_stabilization_window
  scale_down_percent_per_period   = var.hpa_scale_down_percent_per_period

  policy_period_seconds = var.hpa_policy_period_seconds

  depends_on = [kubernetes_deployment.coredns]
}
