# ToggleMaster — Fase 4 · Changelog Técnico

Documento que descreve **o que foi alterado e adicionado** no projeto entre a Fase 3 e a Fase 4 do Tech Challenge, com a justificativa de cada decisão. É a referência primária para a banca avaliadora entender a entrega.

---

## Sumário

1. [Visão geral](#1-visão-geral)
2. [Arquitetura nova](#2-arquitetura-nova)
3. [O que foi adicionado](#3-o-que-foi-adicionado)
4. [O que foi alterado](#4-o-que-foi-alterado)
5. [Mapeamento requisito → entregável](#5-mapeamento-requisito--entregável)

---

## 1. Visão geral

A Fase 4 mantém intacta toda a base das Fases 1‑3 (5 microsserviços conteinerizados, infraestrutura Terraform, CI/CD em GitHub Actions, deploy via ArgoCD em EKS) e **adiciona uma camada de observabilidade total** com:

| Camada | Ferramenta |
|---|---|
| Métricas no cluster | **Prometheus** (via `kube-prometheus-stack`) |
| Logs centralizados | **Loki** (modo SingleBinary) |
| Dashboards | **Grafana** (dashboard customizado provisionado por ConfigMap) |
| Hub OTel | **OpenTelemetry Collector** (DaemonSet) — peça central |
| APM | **Datadog** (Cluster Agent + Node Agent) |
| Roteamento de alertas | **Alertmanager** → **PagerDuty** |
| Notificação ChatOps | **Discord** (via PagerDuty extension) |
| Self-Healing | **Webhook Python in-cluster** que executa rollout-restart |

Tudo é entregue via **GitOps**: cada nova ferramenta é uma `Application` do ArgoCD em `gitops/base/observability/`.

---

## 2. Arquitetura nova

```
┌────────────────────────── AWS EKS (togglemaster-eks) ──────────────────────────┐
│                                                                                 │
│  ┌───── Namespaces de aplicação (Fase 3) ────────────────────────────┐         │
│  │                                                                    │         │
│  │  auth-namespace        flag-namespace        targeting-namespace   │         │
│  │  evaluation-namespace  analytics-namespace                         │         │
│  │                                                                    │         │
│  │  Cada pod expõe :9464/metrics (Fase 4) + envia OTLP via gRPC/HTTP │         │
│  └───────────────────┬────────────────────────────────────────────────┘         │
│                      │ OTLP (4317 gRPC / 4318 HTTP)                            │
│                      ▼                                                          │
│  ┌───── Namespace: observability (NOVO na Fase 4) ────────────────────┐        │
│  │                                                                     │        │
│  │   OpenTelemetry Collector (DaemonSet)                              │        │
│  │     ├── recebe OTLP dos microsserviços                             │        │
│  │     ├── lê filelogs do node (/var/log/pods)                        │        │
│  │     ├── coleta hostmetrics                                          │        │
│  │     ├── enriquece com k8sattributes                                │        │
│  │     └── ROTEIA:                                                     │        │
│  │           ├── traces  ─► Datadog (APM/Service Map)                 │        │
│  │           ├── métricas ─► Prometheus (remote-write)                │        │
│  │           └── logs    ─► Loki (otlphttp/loki)                      │        │
│  │                                                                     │        │
│  │   Prometheus ─► armazena 24h ─► Grafana                            │        │
│  │   Loki       ─► armazena 72h ─► Grafana (datasource adicional)     │        │
│  │   Grafana    ─► dashboard custom + datasources Prom + Loki         │        │
│  │   Alertmanager ─► PagerDuty (severity=critical)                    │        │
│  │   Self-Healing Webhook (pod novo) ─► patcha deployments via API K8s│        │
│  │                                                                     │        │
│  └───────────────────┬────────────────────────────────────────────────┘        │
└──────────────────────┼─────────────────────────────────────────────────────────┘
                       │
                       ▼ (PagerDuty extensions)
   ┌─────────────┐          ┌────────────────┐          ┌──────────────────┐
   │  Discord    │  ◄────── │   PagerDuty    │ ──────►  │ Self-Healing     │
   │  (webhook)  │          │   (incidente)  │          │ Webhook /heal    │
   └─────────────┘          └────────────────┘          └──────────────────┘
                                                                  │
                                                                  ▼
                                                       kubectl rollout restart
                                                       deployment/<service>
```

---

## 3. O que foi adicionado

### 3.1 Stack de observabilidade (`gitops/base/observability/`)

| Arquivo | O quê | Por quê |
|---|---|---|
| `00-namespace.yaml` | Namespace `observability` | Isolamento de RBAC e cleanup unificado |
| `01-kube-prometheus-stack.yaml` | Helm chart consolidado: Prometheus + Grafana + Alertmanager + node-exporter + kube-state-metrics | Ecossistema oficial, mantido pela comunidade, com PrometheusRule/ServiceMonitor CRDs prontos |
| `02-loki.yaml` | Loki em SingleBinary com gateway nginx | Modo enxuto para o AWS Academy; gateway dá 1 endpoint estável |
| `03-otel-collector.yaml` | OpenTelemetry Collector contrib em DaemonSet | **Peça central exigida pelo enunciado**: roteia 3 sinais |
| `04-datadog.yaml` | Datadog Cluster Agent + Node Agent | APM, Service Map e Live Containers |
| `../../templates/alertmanager-pagerduty-config.template.yaml` | Template do Secret Alertmanager → PagerDuty (aplicado com a chave real via workflow/manual; fica FORA do path do ArgoCD para o selfHeal não sobrescrever a chave com o placeholder) | Roteamento e inibição de alertas |
| `06-prometheus-rules.yaml` | PrometheusRule com 6 alertas customizados | Cenário do enunciado (taxa de 5xx) + alertas complementares |
| `07-grafana-dashboard.yaml` | ConfigMap com dashboard JSON do Grafana | Requisito: dashboard custom centralizando cluster + RPS + logs |
| `08-self-healing-app.yaml` | Application do ArgoCD para o webhook | Aponta para `gitops/base/self-healing/` |
| `_app-of-apps.yaml` | Application raiz "observability-stack" | Bootstrap único da stack inteira |

### 3.2 Self-Healing (`services/self-healing-webhook/` + `gitops/base/self-healing/`)

- **`main.py`**: servidor HTTP Python in-cluster que aceita webhooks do Alertmanager/PagerDuty e executa `rollout restart` via API nativa do Kubernetes (sem shellar `kubectl`). Inclui:
  - Log estruturado JSON (visível no Loki) → **prova auditável da execução automática**.
  - Rate-limit de 5 min por deployment → evita "self-DDoS" em flapping.
  - Whitelist de namespaces via regex → só restarta serviços do ToggleMaster.
- **`Dockerfile`**: imagem mínima Python 3.11-slim, usuário não-root, filesystem read-only.
- **`deployment.yaml`** + RBAC: ServiceAccount com ClusterRole minimal (`get/list/patch` em `deployments`).

### 3.3 Instrumentação OpenTelemetry

**Serviços Python (flag, targeting, analytics):**
- Novo módulo `telemetry.py` em cada serviço, idempotente.
- 8 pacotes adicionados ao `requirements.txt` cobrindo SDK + exporters OTLP/Prometheus + auto-instrumentação de Flask, requests, psycopg2, botocore, logging.

**Serviços Go (auth, evaluation):**
- Novo pacote `telemetry/` em cada serviço.
- 8 módulos OTel adicionados ao `go.mod`.
- `WrapHandler` (otelhttp) embrulha o mux → spans por request.
- `WrapTransport` embrulha o `http.Client` outbound → propagação de `traceparent` para o próximo serviço (essencial para o Service Map).

### 3.4 ECR e CI/CD

- Nova variável `infra_images` em `terraform/variables.tf` lista as imagens auxiliares (hoje: `self-healing-webhook`).
- Módulo ECR agora cria **6 repositórios** (5 microsserviços + 1 webhook).
- Workflow `cicd-services.yml` ganhou job `ci-self-healing` reaproveitando o workflow reutilizável existente.

---

## 4. O que foi alterado

### 4.1 Deployments dos 5 microsserviços (`gitops/base/{auth,flag,targeting,evaluation,analytics}/deployment.yaml`)

Mesmo padrão aplicado em todos:

```yaml
metadata:
  labels:
    # NOVO — labels unified-service-tagging do Datadog
    tags.datadoghq.com/service: <service>
    tags.datadoghq.com/env: production
    tags.datadoghq.com/version: "1.0.0"
spec:
  template:
    metadata:
      labels: { ...as labels acima... }
      annotations:
        # NOVO — scrape do Prometheus em pod-level (compat com a config do KPS)
        prometheus.io/scrape: "true"
        prometheus.io/port:   "9464"
        prometheus.io/path:   "/metrics"
        # NOVO — descoberta automática do Datadog Agent
        ad.datadoghq.com/<service>.logs: '[{"source":"<lang>","service":"<service>"}]'
    spec:
      containers:
        - ports:
            - { containerPort: 80XX, name: http }
            # NOVO — porta 9464 do exporter Prometheus do OTel SDK
            - { containerPort: 9464, name: metrics }
          env:
            # NOVAS env vars OTel + Datadog
            - { name: OTEL_SERVICE_NAME, value: "<service>" }
            - { name: OTEL_EXPORTER_OTLP_ENDPOINT, value: "http://otel-..:4318" }
            - { name: OTEL_EXPORTER_OTLP_PROTOCOL, value: "http/protobuf" }
            - { name: OTEL_RESOURCE_ATTRIBUTES, value: "..." }
            - { name: DD_SERVICE, valueFrom: { fieldRef: ... } }
            - { name: DD_ENV,     valueFrom: { fieldRef: ... } }
            - { name: DD_VERSION, valueFrom: { fieldRef: ... } }
```

### 4.2 Dockerfiles

Cada um dos 5 Dockerfiles agora expõe **9464** além da porta da API. Os comentários no Dockerfile explicam por quê (`/metrics` no formato Prometheus).

### 4.3 Código-fonte

| Serviço | Arquivo | Mudança |
|---|---|---|
| auth-service | `main.go` | Chama `telemetry.Init`, embrulha mux com `WrapHandler`, graceful shutdown |
| auth-service | `go.mod` | +8 deps OTel + `client_golang` |
| evaluation-service | `main.go` | Idem auth + `HttpClient.Transport = telemetry.WrapTransport(...)` para propagar trace context outbound |
| evaluation-service | `go.mod` | +8 deps OTel |
| flag-service | `app.py` | `init_telemetry(flask_app=app, service_name="flag-service")` logo após `app = Flask(...)` |
| flag-service | `requirements.txt` | +9 pacotes OTel |
| flag-service | `telemetry.py` | NOVO (copiado de `_shared/`) |
| targeting-service | Idem flag |  |
| analytics-service | Idem flag (com auto-instrument botocore para SQS/DynamoDB) |  |

### 4.4 Terraform

| Arquivo | Mudança |
|---|---|
| `variables.tf` | Nova `infra_images` (lista para ECR sem virar microsserviço) |
| `main.tf` | `services = concat(var.services, var.infra_images)` no módulo ECR |
| `modules/argocd/main.tf` | Duas novas `Application` (observability-stack + self-healing-webhook) |

### 4.5 CI/CD

- `cicd-services.yml`: novo path-filter para `services/self-healing-webhook/**` e novo job `ci-self-healing`. O resumo final passou a agregar 6 jobs em vez de 5.

---

## 5. Mapeamento requisito → entregável

| Requisito da Fase 4 | Onde está implementado |
|---|---|
| Prometheus para métricas | `gitops/base/observability/01-kube-prometheus-stack.yaml` |
| Loki para logs | `gitops/base/observability/02-loki.yaml` |
| Grafana com dashboard customizado | `gitops/base/observability/07-grafana-dashboard.yaml` (5 linhas: serviços/RPS/erros/cluster/logs) |
| OTel Collector como peça central | `gitops/base/observability/03-otel-collector.yaml` |
| APM (Datadog ou New Relic) | **Datadog** em `gitops/base/observability/04-datadog.yaml` + traces vindos pelo OTel Collector |
| Instrumentação de código | `services/*/telemetry*` (.py e Go) + chamadas em `app.py` / `main.go` |
| Distributed Tracing | `WrapTransport` no `http.Client` do evaluation-service propaga `traceparent` |
| Service Map | OTLP traces → Datadog (com 5 serviços rotulados em DD_SERVICE) |
| Alerta inteligente | `gitops/base/observability/06-prometheus-rules.yaml` → `HighHttpErrorRate` (taxa 5xx > 5%) |
| Integração PagerDuty | `gitops/templates/alertmanager-pagerduty-config.template.yaml` |
| Notificação no Discord | PagerDuty Service Extension (configurado fora do Git, ver `docs/fase4/DEPLOYMENT.md`) |
| Self-Healing automático | `services/self-healing-webhook/main.py` + `gitops/base/self-healing/deployment.yaml` |
