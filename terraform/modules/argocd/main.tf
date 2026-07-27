

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
          requests = { cpu = "250m", memory = "512Mi" }
          limits   = { cpu = "1000m", memory = "1024Mi" } # Aumentado de 512Mi para 1024Mi
        }
      }
      repoServer = {
        resources = {
          requests = { cpu = "50m", memory = "128Mi" }
          limits   = { cpu = "300m", memory = "256Mi" }
        }
      }

      dex = {
        enabled = false
      }
      notifications = {
        enabled = false
      }

      applicationSet = {
        enabled = false
      }
    })
  ]

  timeout       = 600
  wait          = true
  wait_for_jobs = true

  depends_on = [kubernetes_namespace.argocd]
}


resource "kubectl_manifest" "applications" {
  for_each = toset(var.services)

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

      - RespectIgnoreDifferences=true
    retry:
      limit: 5
      backoff:
        duration: 10s
        factor: 2
        maxDuration: 3m

  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas
YAML

  depends_on = [helm_release.argocd]
}


resource "kubectl_manifest" "ingress_app" {
  yaml_body = <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: togglemaster-ingress
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${var.gitops_repo_url}
    targetRevision: ${var.gitops_revision}
    path: gitops/base/ingress
  destination:
    server: https://kubernetes.default.svc
    namespace: togglemaster-edge
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


resource "kubectl_manifest" "observability_app" {
  yaml_body = <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: observability-stack
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${var.gitops_repo_url}
    targetRevision: ${var.gitops_revision}
    path: gitops/base/observability
    directory:
      recurse: false   # Não recursar — os subdirs são geridos pelas child apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true    # CRDs grandes (Prometheus Operator) precisam
      - ApplyOutOfSyncOnly=true
    retry:
      limit: 10
      backoff:
        duration: 30s
        factor: 2
        maxDuration: 10m
YAML

  depends_on = [helm_release.argocd]
}


resource "kubectl_manifest" "self_healing_app" {
  yaml_body = <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: self-healing-webhook
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${var.gitops_repo_url}
    targetRevision: ${var.gitops_revision}
    path: gitops/base/self-healing
  destination:
    server: https://kubernetes.default.svc
    namespace: observability
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
    retry:
      limit: 5
      backoff:
        duration: 10s
        factor: 2
        maxDuration: 3m
YAML

  depends_on = [helm_release.argocd, kubectl_manifest.observability_app]
}
