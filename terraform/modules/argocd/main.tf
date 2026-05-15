# =============================================================================
# Módulo: ArgoCD
# Instala o ArgoCD no cluster EKS via Helm chart oficial.
#
# Depois do apply, a UI do ArgoCD fica acessível via port-forward:
#   kubectl -n argocd port-forward svc/argocd-server 8080:443
# Login inicial:
#   user: admin
#   pass: kubectl -n argocd get secret argocd-initial-admin-secret \
#           -o jsonpath="{.data.password}" | base64 -d
# =============================================================================

terraform {
  required_providers {
    kubectl = {
      source = "gavinbunney/kubectl"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
    helm = {
      source = "hashicorp/helm"
    }
  }
}

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.chart_version
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  # Mantemos o values padrão com poucos ajustes:
  # - server.service.type = LoadBalancer só se var.expose_lb for true (Academy pode não querer).
  # - configs.params: desabilita TLS interno entre client e server (simplifica port-forward).
  values = [
    yamlencode({
      server = {
        service = {
          type = var.expose_lb ? "LoadBalancer" : "ClusterIP"
        }
        extraArgs = ["--insecure"] # permite port-forward em http (https complicaria a demo)
      }
      configs = {
        params = {
          "server.insecure" = true
        }
      }
      # Para o AWS Academy, deixamos os componentes "leves":
      controller = {
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
      }
      repoServer = {
        resources = {
          requests = { cpu = "50m", memory = "128Mi" }
          limits   = { cpu = "300m", memory = "256Mi" }
        }
      }
    })
  ]

  timeout       = 600
  wait          = true
  wait_for_jobs = true

  depends_on = [kubernetes_namespace.argocd]
}

# -----------------------------------------------------------------------------
# Application CRDs — registra as 5 apps do ToggleMaster.
# O ArgoCD vai monitorar o repo GitOps e sincronizar tudo automaticamente.
# -----------------------------------------------------------------------------
resource "kubectl_manifest" "applications" {
  for_each = toset(["auth", "flag", "targeting", "evaluation", "analytics"]) # Ajuste para sua variável de loop

  yaml_body = <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${each.key}
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${var.gitops_repo_url}
    targetRevision: ${var.gitops_revision}
    path: gitops/base/${each.key}
  destination:
    server: https://kubernetes.default.svc
    namespace: ${each.key}-namespace
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - PruneLast=true
    retry:
      limit: 5
      backoff:
        duration: 10s
        factor: 2
        maxDuration: 3m
YAML

  depends_on = [helm_release.argocd]
}