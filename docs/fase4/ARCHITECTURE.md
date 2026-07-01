# ToggleMaster — Fase 4 · Arquitetura de Observabilidade

Documento técnico que aprofunda **como** o pipeline de telemetria foi montado e por que cada peça está onde está.

---

## 1. Fluxos de telemetria (3 sinais)

### 1.1 Traces (caminho da requisição)

```
Cliente HTTP                                    Datadog APM (UI)
    │                                                ▲
    │  HTTP /evaluate                                │
    ▼                                                │
┌────────────────┐  HTTP   ┌────────────────┐  OTLP  │
│ evaluation-svc │ ──────► │  flag-service  │ ─────► │
│                │         └────────────────┘        │
│  ┌─ otelhttp ─┐│  HTTP   ┌────────────────┐        │
│  │  Handler   ││ ──────► │ targeting-svc  │        │
│  └────────────┘│         └────────────────┘        │
│  ┌─ otelhttp ─┐│                                   │
│  │ Transport  ││ ─── traceparent: 00-XXXX-YYYY ────┘
│  └────────────┘│
└────┬───────────┘
     │ OTLP/HTTP via batch                       OTel Collector
     ▼                                          (DaemonSet, 1 por node)
┌────────────────────────────────────────┐  ┌──────────────────────────┐
│ otelhttp instrumenta:                  │  │  receivers:              │
│  - server side  (spans de IN-bound)    │  │    otlp:4317/4318        │
│  - client side  (spans de OUT-bound +  │──┼─►processors:             │
│    propaga `traceparent` no header)    │  │    memory_limiter        │
└────────────────────────────────────────┘  │    k8sattributes  ───────┼──► enriquece com
                                            │    resource              │   k8s.deployment.name,
                                            │    batch                 │   k8s.pod.name etc.
                                            │  exporters:              │
                                            │    datadog ──────────────┼──► Datadog APM
                                            └──────────────────────────┘
```

**Pontos-chave:**
- A *server-side instrumentation* (`otelhttp.NewHandler`) cria 1 span por request entrante.
- A *client-side instrumentation* (`otelhttp.NewTransport`) ADICIONA o header HTTP `traceparent` em cada chamada **outbound**. Sem isso, cada serviço cria seu próprio `trace_id` e o Datadog não consegue ligar evaluation-service → flag-service no Service Map.
- O `k8sattributes` processor enriquece cada span com labels do pod (deployment, node, container) → o Datadog APM mostra "essa span aconteceu no pod X do nó Y" sem nenhum código de aplicação saber disso.

### 1.2 Métricas

```
              ┌─────────────────────────────────────────┐
              │   Microserviço (Go ou Python)            │
              │                                          │
              │  OTel SDK ── MeterProvider               │
              │   ├── PeriodicExporter (OTLP)            │
              │   │     ▼                                │
              │   │   batch a cada 30s                   │
              │   │     ▼                                │
              │   │   OTel Collector (4318/v1/metrics)   │
              │   │     ▼                                │
              │   │   prometheusremotewrite              │
              │   │     ▼                                │
              │   │   Prometheus (kps)                   │
              │   │                                      │
              │   └── PrometheusReader                   │
              │        :9464/metrics  ◄── Prometheus     │
              │                            scrape direto │
              └─────────────────────────────────────────┘

E em paralelo no NODE:
   OTel Collector ── hostmetrics ── CPU/Mem/Disk/Net dos nodes
   OTel Collector ── k8s_cluster ── métricas da API K8s
```

**Por que 2 caminhos para métricas?**

1. **OTLP → Collector → Prometheus** é o caminho "moderno" e oficial. Funciona bem em fluxo normal.
2. **Scrape direto :9464** é o caminho "tradicional", redundante. Funciona MESMO se o Collector falhar.

Em sistemas críticos, redundância de métricas vale o pequeno overhead.

### 1.3 Logs

```
Pods escrevem em stdout/stderr
         │
         ▼
kubelet escreve em /var/log/pods/<ns>_<pod>_<uid>/<container>/N.log
         │
         ▼
OTel Collector (DaemonSet) — filelogreceiver
         │
         ├── parser regex extrai (namespace, pod_name, container) do path
         ├── k8sattributes adiciona deployment, node, app=...
         ├── batch
         │
         ▼
otlphttp/loki exporter ── Loki gateway (nginx)
                            │
                            ▼
                          Loki SingleBinary ── TSDB local
                                  ▲
                                  │
                          Grafana (datasource Loki)
```

**Decisão:** logs vêm do disco do node (filesystem), NÃO do stdout do container, porque:
- `stdout` exige conectar como sidecar via Unix socket (mais frágil).
- `/var/log/pods` já é o que o kubelet escreve no formato CRI.
- O kubelet faz rotation automática — não precisamos nos preocupar com tamanho do log.

---

## 2. Arquitetura do OTel Collector (detalhe)

O Collector tem 3 conceitos centrais:

```
                   ┌─────────────────────────────────────┐
                   │           OTel Collector            │
                   │                                     │
   RECEIVERS  ────►│  otlp ─┐                            │
   filelog ───────►│  filelog ─┐                         │
   hostmetrics ──►│  hostmetrics ─┬─► PROCESSORS         │
   k8s_cluster ──►│  k8s_cluster ┘    memory_limiter    │
                   │                    k8sattributes    │
                   │                    resource         │
                   │                    batch            │
                   │                     │               │
                   │              ┌──────┴────┐          │
                   │              ▼     ▼     ▼          │
                   │           EXPORTERS                 │
                   │  ┌─ datadog        (traces)         │
                   │  ├─ prometheus...  (metrics)        │
                   │  └─ otlphttp/loki  (logs)           │
                   │                                     │
                   └─────────────────────────────────────┘
```

**Pipelines** declaram explicitamente como cada sinal flui:

```yaml
pipelines:
  traces:
    receivers:  [otlp]
    processors: [memory_limiter, k8sattributes, resource, batch]
    exporters:  [datadog, debug]
  metrics:
    receivers:  [otlp, hostmetrics, k8s_cluster]
    processors: [memory_limiter, k8sattributes, resource, batch]
    exporters:  [prometheusremotewrite, datadog]
  logs:
    receivers:  [otlp, filelog]
    processors: [memory_limiter, k8sattributes, resource, batch]
    exporters:  [otlphttp/loki, datadog]
```

> **Note** que `traces` NÃO vai para o Loki — não faz sentido. E `logs` NÃO vai para o Prometheus — também não faz sentido. O Collector é declarativo o suficiente para gente desenhar EXATAMENTE para onde cada sinal vai.

---

## 3. Self-Healing — fluxo do incidente

```
Prometheus dispara alerta `HighHttpErrorRate` (taxa 5xx > 5%)
   │
   ▼
Alertmanager recebe a regra
   ├── matcher severity=critical          ──► route "pagerduty-critical"
   │       │
   │       ▼
   │     POST https://events.pagerduty.com/v2/enqueue
   │       │
   │       ▼
   │     PagerDuty cria INCIDENTE
   │       ├─► Discord (extension "Generic Webhook V2" → /slack)
   │       │       │
   │       │       ▼
   │       │     Canal #incidents
   │       │
   │       └─► (opcional) Outras integrations
   │
   └── matcher severity=critical AND auto_heal=true ──► route "self-healing-webhook"
           │
           ▼
         POST http://self-healing-webhook.observability:8080/heal
           │
           ▼
         self-healing-webhook (pod Python)
           │
           ├── Valida: labels.namespace match regex?
           ├── Valida: rate-limit OK?
           │
           ▼
         AppsV1Api.patch_namespaced_deployment(...)
           │
           ▼
         Kubernetes faz rolling restart do deployment
           │
           ▼
         Log JSON {msg: "auto_heal_executed", ok: true, ...}
           │
           ▼
         OTel Collector (filelog) ──► Loki
                                       │
                                       ▼
                                    Grafana dashboard mostra o restart
                                    em tempo real (linha 5: "logs")
```

**Por que duas rotas separadas para o mesmo alerta?**

A rota PagerDuty é **informativa** (humano olha o Discord, faz ack no PagerDuty). A rota self-healing é **automática** (sem intervenção humana). Mantê-las separadas no Alertmanager permite tunar **independentemente**:

- PagerDuty: `group_wait: 10s` para acordar humanos só uma vez por minuto.
- Self-healing: `group_wait: 0s` porque queremos curar IMEDIATAMENTE.

E o `continue: true` na rota PagerDuty faz com que o Alertmanager também avalie a próxima rota — se ambas matchearem, AMBAS disparam.

---

## 4. RBAC do Self-Healing — princípio do menor privilégio

```yaml
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "patch"]    # ← NÃO inclui delete, create, ou update
  - apiGroups: [""]
    resources: ["pods", "events"]
    verbs: ["get", "list"]              # ← Read-only, para diagnóstico
```

**O que o webhook NÃO pode fazer:**
- Deletar pods / deployments / namespaces
- Escalar (replica count)
- Mexer em ConfigMaps, Secrets, Services, Ingress
- Atuar fora dos namespaces da regex `^(auth|evaluation|flag|targeting|analytics)-namespace$`

**O que ele pode fazer:**
- Apenas `patch` no template do deployment (adiciona a anotação `kubectl.kubernetes.io/restartedAt`), o que dispara um rolling restart.

Se o webhook fosse comprometido, o blast radius é limitado a: **causar restart de até 5 deployments dos serviços do ToggleMaster**. Nada de exfiltração de dados, escalada de privilégios, ou movimento lateral.

---

## 5. Métricas que importam (Golden Signals)

| Signal | Métrica | Onde está no dashboard |
|---|---|---|
| Traffic | `rate(http_requests_total[2m])` | Linha 2, gráfico esquerdo |
| Errors | `rate(http_requests_total{http_response_status_code=~"5.."}[2m])` | Linha 3, gráfico esquerdo |
| Latency | `histogram_quantile(0.95, ...)` | Linha 2, gráfico direito |
| Saturation | `container_memory_working_set_bytes / container_spec_memory_limit_bytes` | Alerta `HighMemoryUsage` |

O dashboard customizado em `07-grafana-dashboard.yaml` cobre os 4 acima + bonus (estado dos serviços e contagem de alertas firing).
