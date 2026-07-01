# ToggleMaster — Tech Challenge Fase 4

Sistema de feature flags com **5 microsserviços** rodando em **AWS EKS**, provisionado por **Terraform**, com pipeline DevSecOps no **GitHub Actions**, entrega contínua via **ArgoCD** — agora com **observabilidade total**: Prometheus + Loki + Grafana + OpenTelemetry Collector + Datadog APM + PagerDuty → Discord → Self-Healing automático.

> Fase 4 do PosTech / FIAP, executado no **AWS Academy** com a `LabRole` existente. O Terraform não cria nenhuma IAM Role ou Policy.

---

## Onde olhar primeiro

| Documento | Para quem | Leitura |
|---|---|---|
| **[docs/fase4/CHANGES.md](docs/fase4/CHANGES.md)** | Banca avaliadora — entender O QUE e POR QUÊ mudou | 10 min |
| **[docs/fase4/ARCHITECTURE.md](docs/fase4/ARCHITECTURE.md)** | Pessoa técnica — entender COMO o pipeline de telemetria funciona | 15 min |
| **[docs/fase4/DEPLOYMENT.md](docs/fase4/DEPLOYMENT.md)** | Para subir/derrubar o ambiente no AWS Academy | 20 min |
| **[docs/fase4/RELATORIO.pdf](docs/fase4/RELATORIO.pdf)** | Entrega oficial da Fase 4 | — |

---

## Arquitetura — visão de 30 segundos

```
Microsserviços (5)  --> OTel Collector (DaemonSet) -+-> Datadog APM (traces)
                                                    +-> Prometheus (métricas)
                                                    +-> Loki (logs)
                                                              |
                                                              v
                                                            Grafana
                                                              |
                                                         Alertmanager
                                                              |
                                                         PagerDuty -+-> Discord (notify)
                                                                    +-> Self-Healing /heal
                                                                              |
                                                                              v
                                                                    kubectl rollout restart
```

---

## Estrutura do repositório

```
togglemaster-fase4/
├── .github/workflows/           # CI/CD (atualizado: +ci-self-healing)
├── docs/fase4/                  # Documentação da Fase 4 (NOVO)
│   ├── CHANGES.md
│   ├── ARCHITECTURE.md
│   ├── DEPLOYMENT.md
│   ├── RELATORIO.md / .pdf
│   └── evidencias/              # Prints para o relatório
├── gitops/base/
│   ├── auth/                    # atualizado: OTel env vars + scrape annotations
│   ├── flag/                    # idem
│   ├── targeting/               # idem
│   ├── evaluation/              # idem
│   ├── analytics/               # idem
│   ├── ingress/                 # sem alteração
│   ├── observability/           # NOVO: stack inteira da Fase 4 (10 manifestos)
│   └── self-healing/            # NOVO: pod webhook que executa rollout-restart
├── services/
│   ├── auth-service/            # +telemetry/ (Go) — instrumentação OTel
│   ├── flag-service/            # +telemetry.py (Python) — idem
│   ├── targeting-service/       # +telemetry.py
│   ├── evaluation-service/      # +telemetry/ + WrapTransport no HttpClient
│   ├── analytics-service/       # +telemetry.py (auto-instrument boto3)
│   ├── self-healing-webhook/    # NOVO: pod Python que executa rollout-restart
│   └── _shared/telemetry.py     # Source-of-truth do módulo Python
└── terraform/
    ├── modules/argocd/main.tf   # +2 Applications (observability + self-healing)
    └── variables.tf             # +infra_images
```

---

## Setup rápido

```bash
# 1. Provisionar a infra (Terraform)
cd terraform/
terraform init && terraform apply

# 2. Criar Secrets externos (NÃO commitados)
kubectl create ns observability
kubectl -n observability create secret generic datadog-secret \
  --from-literal=api-key="SUA_DD_KEY" \
  --from-literal=DD_API_KEY="SUA_DD_KEY" \
  --from-literal=DD_SITE="us5.datadoghq.com"

# 3. Aplicar config do Alertmanager com a chave do PagerDuty
sed "s/PAGERDUTY_INTEGRATION_KEY/$PD_KEY/g" \
  gitops/base/observability/05-alertmanager-config.yaml \
  | kubectl apply -f -

# 4. Aguardar ArgoCD sincronizar (3-5 min)
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

Detalhe completo: **[docs/fase4/DEPLOYMENT.md](docs/fase4/DEPLOYMENT.md)**

---

## Requisitos da Fase 4 — checklist

- [x] Prometheus para métricas no K8s
- [x] Loki para logs centralizados
- [x] Grafana com dashboard customizado (5 linhas: serviços, RPS, erros, recursos, logs)
- [x] OpenTelemetry Collector como peça central (DaemonSet, recebe e roteia 3 sinais)
- [x] APM Datadog (For Education plan)
- [x] Instrumentação OTel em todos os 5 microsserviços (Go + Python)
- [x] Distributed Tracing com propagação de `traceparent`
- [x] Service Map mostrando os 5 microsserviços e dependências
- [x] Alerta inteligente `HighHttpErrorRate` (5xx > 5% por 2 min)
- [x] Integração PagerDuty (Developer plan)
- [x] Notificação Discord (via PagerDuty Extension)
- [x] Self-Healing automático (webhook Python in-cluster com RBAC mínimo)
- [x] GitOps mantido (todas as adições por Application do ArgoCD)
- [x] CI/CD estendido para a nova imagem self-healing-webhook

---

## Licença

Projeto acadêmico — FIAP / PosTech.
