# ToggleMaster — Fase 4 · Changelog Técnico

Documento que descreve **o que foi alterado e adicionado** no projeto entre a Fase 3 e a Fase 4 do Tech Challenge, com a justificativa de cada decisão. É a referência primária para a banca avaliadora entender a entrega.

---

## Sumário

1. [Visão geral](#1-visão-geral)
2. [Arquitetura nova](#2-arquitetura-nova)
3. [O que foi adicionado](#3-o-que-foi-adicionado)
4. [O que foi alterado](#4-o-que-foi-alterado)
5. [Decisões de design e por quê](#5-decisões-de-design-e-por-quê)
6. [Mapeamento requisito → entregável](#6-mapeamento-requisito--entregável)

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
| `05-alertmanager-config.yaml` | Secret com configuração do Alertmanager → PagerDuty | Roteamento e inibição de alertas |
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

## 5. Decisões de design e por quê

### Por que OTel Collector como peça central (e não enviar direto para o Datadog)?

Porque o enunciado **exige** o OTel Collector como peça central. Mas é também a decisão tecnicamente certa: se amanhã decidirmos trocar Datadog por New Relic, basta mexer no exporter do Collector — **nenhum código de aplicação muda**. Vendor lock-in fica isolado em 1 lugar.

### Por que DaemonSet (e não Deployment) para o Collector?

O `filelogreceiver` lê `/var/log/pods` do disco do node. Um pod no node A não consegue ler o `/var/log/pods` do node B. Portanto, cada node precisa do seu próprio coletor → DaemonSet.

### Por que tanto OTel Collector E Datadog Agent?

- **OTel Collector** envia os 3 sinais (métricas, logs, traces) via OTLP.
- **Datadog Agent** ainda agrega valor com:
  - **Cluster Agent**: deduplica chamadas à API K8s (evita rate-limit no Academy).
  - **Process Agent**: enche o "Process Map" do Datadog (impossível só com OTel).
- Logs NÃO são coletados pelo Datadog Agent (já estão no Loki) → sem custo duplicado.

### Por que Datadog (e não New Relic)?

| Critério | Datadog | New Relic |
|---|---|---|
| Plano educational | ✅ For Education | ⚠️ Trial limitado |
| Service Map | ✅ Excelente, com latência e throughput inline | ✅ Bom, mas exige UI mais complexa |
| Integração nativa com K8s | ✅ Cluster Agent maduro | ⚠️ Requer config manual de attributes |
| Compatibilidade OTLP | ✅ `datadog` exporter no contrib | ✅ via OTLP nativo |

A escolha foi **Datadog** pela combinação de plano para educação e Service Map mais direto na UI.

### Por que PagerDuty (e não OpsGenie)?

| Critério | PagerDuty | OpsGenie |
|---|---|---|
| Plano gratuito | ✅ Developer plan ilimitado | ⚠️ Free só até 5 usuários |
| Extensão para Discord | ✅ Nativa (webhook genérico) | ⚠️ Requer Zapier |
| Webhook custom para self-healing | ✅ Built-in extension | ✅ Via Actions, mais complexo |
| Documentação para students | ✅ Muito clara | ⚠️ Espalhada |

Escolhido **PagerDuty** principalmente pela facilidade de configurar **duas extensions na mesma policy**: uma para Discord (notificação visual) e outra para o self-healing webhook (ação automática).

### Por que notificar o Discord **via PagerDuty** e não direto do Alertmanager?

Centralização do trail de auditoria. Se Discord viesse direto do Alertmanager E indiretamente do PagerDuty, teríamos duplicidade. Com tudo passando pelo PagerDuty: 1 incidente, 1 timer de MTTA/MTTR, e o Discord vira apenas um "consumer" do incidente — sem inflar métricas.

### Por que self-healing como pod in-cluster (e não AWS Lambda)?

1. **Latência**: pod em-cluster responde em ms; Lambda fora da VPC precisa de NAT.
2. **Auth K8s**: dentro do cluster usamos ServiceAccount + RBAC nativo. Fora, precisaria gerar e rotacionar um kubeconfig com token de longa duração.
3. **Custo no AWS Academy**: Lambda fora do free-tier conta. Pod no node existente é zero adicional.
4. **Debug**: log do pod aparece no Loki — exatamente onde o resto da prova está.

### Por que rate-limit de 5 min no self-healing?

Se o alerta fica oscilando entre `firing` e `resolved` a cada 30s (uma falha intermitente), sem rate-limit o webhook restartaria o deployment a cada 30s → **self-DDoS**. O limite de 5 min é o mesmo SLO que um humano teria ao olhar para a fila do PagerDuty ("ok, já restartei, vou esperar antes de tentar de novo").

### Por que retention de 24h no Prometheus e 72h no Loki?

Os nodes t3.medium do AWS Academy têm 4 GB de RAM e disco EBS limitado. Em produção real, Prometheus seria 15 dias com remote-write para Thanos/Mimir e Loki seria meses com S3. Aqui, retentions curtas são suficientes para **demonstração**.

### Por que `kube-prometheus-stack` em vez dos charts separados?

O `kube-prometheus-stack` traz os 5 itens já bem amarrados: Prometheus + Alertmanager + Grafana + Operator + ServiceMonitors + node-exporter + kube-state-metrics. Cada um separadamente exigiria 5 charts e ~200 linhas a mais de YAML.

### Por que métricas HTTP CUSTOMIZADAS (e não só a auto-instrumentação)?

A auto-instrumentação do OTel (Flask/otelhttp) emite a métrica `http.server.duration`. O problema: ao ser traduzida para o Prometheus, esse nome vira algo **imprevisível entre versões** — `http_server_duration_milliseconds`, `http_server_request_duration_seconds`, etc., dependendo da versão do SDK e da convenção semântica ativa. Alertas e dashboards que dependem de um nome fixo ficariam **vazios** sem aviso.

A solução foi registrar, via middleware (`before_request`/`after_request` no Flask e um `statusRecorder` no Go), duas métricas com nomes **determinísticos**:

- `http_requests_total` — counter com labels `service`, `http_request_method`, `http_route`, `http_response_status_code`
- `http_request_duration_seconds` — histogram em **segundos** com buckets explícitos (`0.005 … 10.0`)

Dois detalhes que validamos empiricamente (rodando o SDK real):

1. **Sufixo `_total` automático**: o exporter Prometheus adiciona `_total` a counters. Por isso o counter é criado como `http_requests` (sem sufixo) e o Prometheus o expõe como `http_requests_total`. Criar já com `_total` resultaria em `http_requests_total_total`.
2. **Buckets em segundos**: os buckets default do histogram OTel são pensados para milissegundos (`0, 5, …, 10000`). Sem uma `View`/`WithExplicitBucketBoundaries` em segundos, o `histogram_quantile` do alerta `HighLatency` (> 2s) daria resultados sem sentido.

Esses nomes são EXATAMENTE os usados em `06-prometheus-rules.yaml` e `07-grafana-dashboard.yaml`.

### Por que pinar `setuptools<81` nos serviços Python?

`opentelemetry-instrumentation` (0.48b0) ainda importa `pkg_resources`, módulo que foi **removido do `setuptools >= 81`**. Em uma imagem `python:3.11-slim` (que não traz `setuptools` antigo), a instrumentação Flask quebraria em runtime com `ModuleNotFoundError: No module named 'pkg_resources'` — derrubando TODA a telemetria do serviço. O pin `setuptools<81` no `requirements.txt` garante que `pkg_resources` exista. Validado rodando o stack real de pacotes.

### Por que criar os secrets de observabilidade no workflow (e não só manual)?

A primeira versão exigia criar o `datadog-secret` e a config do Alertmanager à mão, via `kubectl`. Isso é seguro, mas é trabalho repetitivo a cada novo cluster. A versão atual permite definir três *GitHub Secrets* no repositório (`DD_API_KEY`, `DD_SITE`, `PAGERDUTY_INTEGRATION_KEY`); o job `post-apply-check` do `terraform-infra.yml` então cria os secrets no cluster automaticamente, logo após o ArgoCD subir e antes da stack de observability reconciliar.

Detalhes da implementação que importam:

- **`secrets.X` não funciona em `if:`** no GitHub Actions (avalia sempre como vazio). Por isso um step "gate" lê os secrets via `env` e publica flags em `outputs`; os steps seguintes condicionam por essas flags.
- **Degrada com elegância:** se um secret não estiver definido, o workflow emite um *warning* e segue — não falha. O usuário pode criar aquele secret manualmente depois.
- **Idempotente:** usa `kubectl create ... --dry-run=client -o yaml | kubectl apply -f -`, então rodar o workflow de novo atualiza os secrets em vez de falhar por já existirem.
- **Empurra o ArgoCD:** após criar os secrets, anota as Applications de observability com `argocd.argoproj.io/refresh=hard` para reconciliar na hora (sem isso funcionaria mesmo assim via `selfHeal`, só mais devagar).

A integração **PagerDuty → Discord permanece manual** de propósito: é configurada na UI do PagerDuty (uma Extension com a URL do webhook do Discord) e não há API de Kubernetes que a represente.

---

## 6. Mapeamento requisito → entregável

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
| Integração PagerDuty | `gitops/base/observability/05-alertmanager-config.yaml` |
| Notificação no Discord | PagerDuty Service Extension (configurado fora do Git, ver `docs/fase4/DEPLOYMENT.md`) |
| Self-Healing automático | `services/self-healing-webhook/main.py` + `gitops/base/self-healing/deployment.yaml` |
