# =============================================================================
# Módulo: k8s-bootstrap
# Cria, no cluster recém-provisionado:
#  - 1 namespace por microsserviço
#  - 1 Secret central com as DATABASE_URLs (uma por banco) + REDIS_URL
#  - 1 ConfigMap central com URLs entre serviços, fila SQS e tabela DynamoDB
#  - metrics-server (necessário para o HPA)
#
# Esses Secrets/ConfigMaps são CONSUMIDOS pelos manifests do GitOps via
# `secretKeyRef` / `configMapKeyRef`. Isso resolve dois requisitos do desafio
# de uma vez:
#  1) "As credenciais do banco de dados estão sendo passadas em arquivos de
#     texto sem segurança" -> agora vêm de um Secret K8s gerado pelo Terraform
#     a partir do random_password (sem credencial no Git).
#  2) "Se não está no código, não existe" -> tudo é declarado em Terraform.
# =============================================================================

# -----------------------------------------------------------------------------
# Namespaces (1 por microsserviço)
# -----------------------------------------------------------------------------
resource "kubernetes_namespace" "app" {
  for_each = toset(var.services)
  metadata {
    name = "${each.key}-namespace"
    labels = {
      "app.kubernetes.io/part-of" = "togglemaster"
      "managed-by"                = "terraform"
    }
  }
}

# -----------------------------------------------------------------------------
# Secret de banco em CADA namespace que precisa de DB
# (auth, flag, targeting). Conteúdo: DATABASE_URL pronta.
# -----------------------------------------------------------------------------
resource "kubernetes_secret" "db_url" {
  for_each = toset(var.db_services) # ["auth", "flag", "targeting"]

  metadata {
    name      = "togglemaster-db-secret"
    namespace = kubernetes_namespace.app[each.key].metadata[0].name
  }

  data = {
    # Connection string completa (libpq) — é o que as apps esperam (DATABASE_URL).
    DATABASE_URL = var.db_connection_urls[each.key]
    # Variáveis individuais (úteis para o Job de init via psql).
    DB_HOST     = var.db_endpoints[each.key]
    DB_USER     = var.db_master_username
    DB_PASSWORD = var.db_passwords[each.key]
    DB_NAME     = each.key
  }

  type = "Opaque"
}

# -----------------------------------------------------------------------------
# ConfigMap por namespace com configurações compartilhadas:
#  - Redis URL (para evaluation/analytics)
#  - URLs internas entre serviços (cluster.local)
#  - Fila SQS
#  - Tabela DynamoDB
# -----------------------------------------------------------------------------
resource "kubernetes_config_map" "shared" {
  for_each = toset(var.services)

  metadata {
    name      = "togglemaster-config"
    namespace = kubernetes_namespace.app[each.key].metadata[0].name
  }

  data = {
    REDIS_URL              = var.redis_url
    AUTH_SERVICE_URL       = "http://auth-service.auth-namespace.svc.cluster.local:8001"
    FLAG_SERVICE_URL       = "http://flag-service.flag-namespace.svc.cluster.local:8002"
    TARGETING_SERVICE_URL  = "http://targeting-service.targeting-namespace.svc.cluster.local:8003"
    EVALUATION_SERVICE_URL = "http://evaluation-service.evaluation-namespace.svc.cluster.local:8004"
    AWS_REGION             = var.aws_region
    AWS_SQS_URL            = var.sqs_queue_url
    AWS_DYNAMODB_TABLE     = var.dynamodb_table_name
  }
}

# -----------------------------------------------------------------------------
# Secret para o SERVICE_API_KEY do evaluation-service.
# Gerado uma vez aqui e disponibilizado para o pod via envFrom.
# -----------------------------------------------------------------------------
resource "random_password" "service_api_key" {
  length  = 48
  special = false
}

resource "kubernetes_secret" "evaluation_extra" {
  metadata {
    name      = "evaluation-extra-secret"
    namespace = kubernetes_namespace.app["evaluation"].metadata[0].name
  }

  data = {
    SERVICE_API_KEY = "tm_key_${random_password.service_api_key.result}"
  }

  type = "Opaque"
}

# -----------------------------------------------------------------------------
# Secret extra do auth-service: a MASTER_KEY usada para gerar API keys.
# -----------------------------------------------------------------------------
resource "random_password" "auth_master_key" {
  length  = 32
  special = false
}

resource "kubernetes_secret" "auth_extra" {
  metadata {
    name      = "auth-extra-secret"
    namespace = kubernetes_namespace.app["auth"].metadata[0].name
  }

  data = {
    MASTER_KEY = random_password.auth_master_key.result
  }

  type = "Opaque"
}

# -----------------------------------------------------------------------------
# metrics-server — necessário para HPA funcionar (analytics e evaluation
# têm HPA por CPU).
# -----------------------------------------------------------------------------
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
  version    = "3.12.1"

  set {
    name  = "args"
    value = "{--kubelet-insecure-tls,--kubelet-preferred-address-types=InternalIP}"
  }
}
