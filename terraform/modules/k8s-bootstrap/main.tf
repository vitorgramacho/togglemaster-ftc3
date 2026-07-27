

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


resource "kubernetes_secret" "db_url" {
  for_each = toset(var.db_names) # ["auth", "flag", "targeting"]

  metadata {
    name = "togglemaster-db-secret"
    # Como o namespace se chama "auth-namespace" (sem o "db"), 
    # usamos replace() para remover o "db" do final da chave temporariamente aqui.
    namespace = kubernetes_namespace.app[replace(each.key, "db", "")].metadata[0].name
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

resource "kubernetes_secret" "aws_credentials" {
  for_each = kubernetes_namespace.app

  metadata {
    name      = "aws-credentials"
    namespace = each.value.metadata[0].name
  }

  data = {
    AWS_ACCESS_KEY_ID     = var.aws_access_key_id
    AWS_SECRET_ACCESS_KEY = var.aws_secret_access_key
    AWS_SESSION_TOKEN     = var.aws_session_token
  }

  type = "Opaque"
}

# Cópia do SERVICE_API_KEY no namespace do auth-service.
# Necessário para o Job `auth-seed-apikey` (que roda em auth-namespace)
# poder ler o valor sem cruzar namespaces — secretKeyRef não permite
# referências cross-namespace no Kubernetes.
resource "kubernetes_secret" "service_api_key_in_auth" {
  metadata {
    name      = "evaluation-service-apikey"
    namespace = kubernetes_namespace.app["auth"].metadata[0].name
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


resource "kubernetes_namespace" "ingress_nginx" {
  metadata {
    name = "ingress-nginx"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  namespace  = kubernetes_namespace.ingress_nginx.metadata[0].name
  version    = "4.10.1"

  # LoadBalancer: o AWS Cloud Controller Manager cria um NLB automaticamente
  # e registra os nodes do EKS como targets. Você recebe um DNS estável na
  # porta 80 sem precisar configurar nada manualmente na AWS.
  # Em AWS Academy, a LabRole já tem permissão para criar NLBs via EKS.
  set {
    name  = "controller.service.type"
    value = "LoadBalancer"
  }

  # Necessário no EKS: deixa o controller ler IngressClass em todos os namespaces.
  set {
    name  = "controller.ingressClassResource.default"
    value = "true"
  }

  # Publica métricas para o metrics-server.
  set {
    name  = "controller.metrics.enabled"
    value = "true"
  }

  timeout       = 300
  wait          = true
  wait_for_jobs = true

  depends_on = [
    kubernetes_namespace.ingress_nginx,
    helm_release.metrics_server,
  ]
}
