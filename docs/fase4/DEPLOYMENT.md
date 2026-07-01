# ToggleMaster — Fase 4 · Guia de Deployment (AWS Academy)

Passo-a-passo para subir o ambiente completo da Fase 4 a partir do zero, usando uma sessão **AWS Academy** (com a `LabRole` já existente).

---

## Pré-requisitos

1. **AWS Academy Lab iniciado** — copie as credenciais temporárias da página "AWS Details":
   ```bash
   export AWS_ACCESS_KEY_ID=...
   export AWS_SECRET_ACCESS_KEY=...
   export AWS_SESSION_TOKEN=...
   export AWS_REGION=us-east-1
   ```
2. **Ferramentas locais**:
   - `terraform >= 1.6`
   - `kubectl >= 1.28`
   - `aws-cli >= 2.x`
   - `helm >= 3.13`
3. **Repositório Git público ou com PAT** com este código (necessário para o ArgoCD clonar).
4. **Contas criadas previamente** (gratuitas):
   - Datadog → anote `API_KEY` e `SITE` (ex: `us5.datadoghq.com`)
   - PagerDuty → crie um *Service* com integração "Events API V2" e anote a `Integration Key`
   - Discord → crie um webhook em qualquer canal e anote a URL

---

## Etapa 1 — Provisionar a infraestrutura

```bash
cd terraform/
cp terraform.tfvars.example terraform.tfvars
# Edite terraform.tfvars colocando:
#   gitops_repo_url = "https://github.com/SEU-USUARIO/togglemaster-fase4.git"
#   gitops_revision = "main"

terraform init
terraform apply -auto-approve
```

Saída esperada (resumida):
```
Apply complete! Resources: ~80 added.
Outputs:
  cluster_name = "togglemaster-eks-prod"
  ecr_urls = {
    "auth"                 = "604720765096.dkr.ecr.us-east-1.amazonaws.com/togglemaster-auth"
    "self-healing-webhook" = "604720765096.dkr.ecr.us-east-1.amazonaws.com/togglemaster-self-healing-webhook"
    ...
  }
```

Configure o kubectl:
```bash
aws eks update-kubeconfig --name togglemaster-eks-prod --region us-east-1
kubectl get nodes   # confirma 2 nodes t3.medium prontos
```

---

## Etapa 2 — Criar os Secrets externos (NÃO commitados no Git)

A stack de observabilidade depende de 2 secrets que **NUNCA** devem ir para o Git:

### 2.1 Datadog (`datadog-secret`)

```bash
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -

kubectl -n observability create secret generic datadog-secret \
  --from-literal=api-key="SUA_DD_API_KEY" \
  --from-literal=DD_API_KEY="SUA_DD_API_KEY" \
  --from-literal=DD_SITE="us5.datadoghq.com"
```

> **Por que dois nomes de chave (`api-key` e `DD_API_KEY`)?**
> O Helm chart do Datadog procura por `api-key`. O OTel Collector lê pela env var `DD_API_KEY`. Mesmo valor, dois nomes para evitar dois Secrets.

### 2.2 Alertmanager → PagerDuty (`alertmanager-pagerduty-config`)

O arquivo em `gitops/base/observability/05-alertmanager-config.yaml` contém um **placeholder** literal `PAGERDUTY_INTEGRATION_KEY`. Substitua e aplique:

```bash
export PD_KEY="suaIntegrationKeyDoPagerDuty"

sed "s/PAGERDUTY_INTEGRATION_KEY/$PD_KEY/g" \
  gitops/base/observability/05-alertmanager-config.yaml \
  | kubectl apply -f -
```

> **NÃO** commite o resultado. O Git mantém o arquivo com placeholder; o cluster recebe a versão com a chave real.

---

## Etapa 3 — Build & push das imagens

O Terraform já criou os 6 repositórios ECR. Faça login e build:

> **Recomendado antes do build:** valide localmente que os serviços Go compilam
> com as novas dependências OpenTelemetry (o ambiente onde o código foi gerado
> não tinha acesso de rede ao `go.opentelemetry.io` para compilar de fato):
> ```bash
> cd services/auth-service       && go build ./... && cd ../..
> cd services/evaluation-service && go build ./... && cd ../..
> ```
> Se faltar `go.sum`, rode `go mod tidy` antes (o Dockerfile já faz isso no build).

```bash
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin \
    604720765096.dkr.ecr.us-east-1.amazonaws.com

# Cada serviço (5 microsserviços + self-healing)
for svc in auth flag targeting evaluation analytics self-healing-webhook; do
  cd services/${svc}-service 2>/dev/null || cd services/${svc}
  TAG="v1.0.0-fase4-$(git rev-parse --short HEAD)"
  ECR_URL="604720765096.dkr.ecr.us-east-1.amazonaws.com/togglemaster-${svc}"

  docker build -t ${ECR_URL}:${TAG} .
  docker push ${ECR_URL}:${TAG}

  # Atualiza o deployment.yaml com a nova tag
  sed -i "s|image: ${ECR_URL}:.*|image: ${ECR_URL}:${TAG}|" \
    ../../gitops/base/${svc%-service}/deployment.yaml

  cd ../..
done

git add gitops/base && git commit -m "fase4: atualiza tags das imagens" && git push
```

> Em produção, este loop é o que o **GitHub Actions** faz automaticamente em cada push.

---

## Etapa 4 — Bootstrap do ArgoCD (a stack inteira sobe sozinha)

O Terraform já registrou as `Application` necessárias. Verifique no ArgoCD:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443 &
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)
echo "ArgoCD admin password: $ARGOCD_PASSWORD"
# Abra https://localhost:8080 e logue como admin
```

No painel você verá:
- 5 Apps de microsserviços (Fase 3): **Synced**
- `togglemaster-ingress`: **Synced**
- `observability-stack` (NOVA): **Syncing → Synced** (leva 3‑5 min)
- `self-healing-webhook` (NOVA): **Synced**

Force um sync se ficar parado:
```bash
kubectl -n argocd patch application observability-stack \
  --type merge -p '{"operation":{"sync":{}}}'
```

---

## Etapa 5 — Configurar PagerDuty → Discord (na UI do PagerDuty)

1. Entre no seu **PagerDuty Service**.
2. Aba **Integrations** → **Add an Integration** → **Extensions**.
3. **Extension Type**: "Generic Webhook V2".
4. **Name**: `Discord Notify`.
5. **URL**: cole o webhook do Discord, **acrescentando `/slack` no final** (o PagerDuty envia um payload Slack-compatible que o Discord entende com esse sufixo).
   - Exemplo: `https://discord.com/api/webhooks/XXX/YYY/slack`
6. **Save**.

Pronto. Daqui em diante, **todo incidente do PagerDuty cai no canal do Discord automaticamente**.

> Decisão técnica: a Fase 4 exige notificação no Discord. Em vez de configurar o `discord_configs` no Alertmanager (suportado), preferimos PagerDuty → Discord para que o **incidente continue sendo a single source of truth** (com ack, MTTA, MTTR).

---

## Etapa 6 — Validação rápida

```bash
# 1) Stack de observability subiu?
kubectl -n observability get pods
# Esperado: kps-..., loki-0, otel-..., datadog-..., alertmanager-..., grafana-..., self-healing-webhook-...

# 2) Métricas chegando no Prometheus?
kubectl -n observability port-forward svc/kps-kube-prometheus-stack-prometheus 9090 &
# Abra http://localhost:9090 → Status → Targets → todos UP

# 3) Logs chegando no Loki?
kubectl -n observability port-forward svc/grafana 3000 &
# Login em http://localhost:3000 (admin / postech2026)
# Explore → Loki → {namespace="auth-namespace"} → deve mostrar logs

# 4) Traces chegando no Datadog?
# Faça uma requisição: curl http://<INGRESS_URL>/evaluate?user_id=u1&flag_name=feature_a
# Datadog → APM → Service Map → 5 nós aparecem (auth, flag, targeting, evaluation, analytics)
```

---

## Etapa 7 — Demonstrando o Self-Healing (a "prova real")

A demonstração do enunciado:

```bash
# Terminal 1: assista o pod do evaluation-service
watch kubectl -n evaluation-namespace get pods

# Terminal 2: faça erro proposital — derrube uma dependência crítica
# Opção A: Mate o cache Redis (mais limpa)
kubectl -n evaluation-namespace exec deploy/evaluation-service -- \
  sh -c "while true; do wget -qO- http://nonexistent-service/error; done"

# Opção B: edite o ENV pra apontar para um FLAG_SERVICE_URL errado
kubectl -n evaluation-namespace patch deployment evaluation-service \
  --type='json' \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/env/2/value","value":"http://flag-broken:9999"}]'

# Em 2-5 minutos:
#  1. O HighHttpErrorRate alert vira "firing" no Prometheus.
#  2. O Alertmanager envia para o PagerDuty.
#  3. PagerDuty abre incidente E notifica o Discord.
#  4. PagerDuty (ou Alertmanager direto, ver 05-) chama o webhook.
#  5. O webhook executa `kubectl rollout restart deployment/evaluation-service`.
#  6. Você vê no Terminal 1 os pods velhos terminando e os novos subindo.

# Confirme o log do self-healing (a PROVA do requisito):
kubectl -n observability logs deploy/self-healing-webhook --tail=20
# Esperado: linha JSON com {"msg": "auto_heal_executed", "service": "evaluation-service", "ok": true, ...}
```

---

## Troubleshooting

| Sintoma | Causa provável | Solução |
|---|---|---|
| ArgoCD App `kube-prometheus-stack` em "OutOfSync" eterno | CRDs do Prometheus Operator demoram p/ criar | Aumente o `retry` ou `kubectl apply --server-side` manualmente os CRDs |
| `datadog-cluster-agent` em CrashLoop | DD_API_KEY inválida ou Secret sem o campo `api-key` | `kubectl -n observability describe pod datadog-cluster-agent-...` |
| Pods OTel em CrashLoop com "address already in use" | Outro DaemonSet usando `hostPort: 4317` | Edite `03-otel-collector.yaml`, remova `hostPort` |
| Alertmanager mostra "no configuration loaded" | Esqueceu de substituir `PAGERDUTY_INTEGRATION_KEY` | Re-execute o `sed` da Etapa 2.2 |
| Discord não recebe notificação | URL do webhook sem o sufixo `/slack` | Edite a Extension no PagerDuty |
| Self-healing não reage ao alerta | RBAC bloqueando o patch | `kubectl auth can-i patch deployments --as=system:serviceaccount:observability:self-healing-webhook -n auth-namespace` |

---

## Teardown (importante no AWS Academy — créditos finitos!)

```bash
cd terraform/
terraform destroy -auto-approve
# Demora ~15min porque tem VPC + EKS + RDS + ElastiCache.
```
