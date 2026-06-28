# ToggleMaster — Tech Challenge Fase 3

Sistema de feature flags com 5 microsserviços (auth, flag, targeting, evaluation, analytics) rodando em AWS EKS, provisionado inteiramente por Terraform, com pipeline DevSecOps no GitHub Actions e entrega contínua via ArgoCD.

> Projeto do PosTech — Tech Challenge Fase 3, executado no AWS Academy com a `LabRole` existente (Opção A do enunciado). O Terraform não cria nenhuma IAM Role ou Policy.

---

## Sumário

1. [Arquitetura](#arquitetura)
2. [Estrutura do repositório](#estrutura-do-repositório)
3. [Como executar](#como-executar)
4. [Workflows do GitHub Actions](#workflows-do-github-actions)
5. [DevSecOps — o pipeline](#devsecops--o-pipeline)
6. [Testando os microsserviços](#testando-os-microsserviços)

---

## Arquitetura

```
┌─────────────────────────────────────────────────────────────────────┐
│                           AWS Account                               │
│                                                                     │
│  ┌──── Terraform (S3 backend + use_lockfile) ───────────────────┐  │
│  │                                                               │  │
│  │  VPC 10.0.0.0/16                                             │  │
│  │   ├─ public  subnets (2 AZs) ─── IGW ── Internet            │  │
│  │   └─ private subnets (2 AZs) ─── NAT                        │  │
│  │        │                                                     │  │
│  │        ├─ EKS Cluster (LabRole)                              │  │
│  │        │    └─ Node Group t3.medium (2 nodes)                │  │
│  │        │         └─ ingress-nginx (type: LoadBalancer) ──────┼──┼── NLB ── Internet
│  │        │         └─ ArgoCD (Helm) ── monitora GitOps ──────┐ │  │
│  │        │                                                    │ │  │
│  │        ├─ RDS PostgreSQL × 3  (authdb, flagdb, targetingdb) │ │  │
│  │        ├─ ElastiCache Redis                                  │ │  │
│  │        ├─ DynamoDB (ToggleMasterAnalytics)                   │ │  │
│  │        └─ SQS (togglemaster-queue + DLQ)                     │ │  │
│  │                                                              │ │  │
│  │  ECR × 5  (auth, flag, targeting, evaluation, analytics)     │ │  │
│  │  Secrets Manager (credenciais geradas pelo Terraform)        │ │  │
│  └──────────────────────────────────────────────────────────────┘ │  │
│                                                            ▼       │  │
│                                              ┌── GitHub ──────┐   │  │
│         ◀── CI: push image → ECR ────────────│  - services/   │   │  │
│         ◀── CI: bump tag em gitops/base/ ────│  - terraform/  │   │  │
│                                              │  - gitops/     │   │  │
│                                              └────────────────┘   │  │
└───────────────────────────────────────────────────────────────────┘  │
```

**Fluxo end-to-end:**

1. Dev faz push em `services/<nome>-service/**`
2. Workflow `cicd-services.yml` roda os 5 estágios DevSecOps só para o serviço modificado (jobs paralelos com paths-filter)
3. CI publica a imagem no ECR e faz commit em `gitops/base/<serviço>/deployment.yaml` com a nova tag
4. ArgoCD detecta o commit e sincroniza a nova versão no EKS automaticamente (`selfHeal: true`, `prune: true`)

**Roteamento externo:**

```
Internet → NLB (criado pelo Kubernetes) → ingress-nginx → pods
               /auth/**       → auth-service:8001
               /flags/**      → flag-service:8002
               /targeting/**  → targeting-service:8003
               /evaluation/** → evaluation-service:8004
               /analytics/**  → analytics-service:8005
```

---

## Estrutura do repositório

```
.
├── .github/workflows/
│   ├── _reusable-cicd.yml      ← motor reutilizável dos pipelines
│   ├── cicd-services.yml       ← 5 jobs paralelos (1 por serviço)
│   └── terraform-infra.yml     ← provisiona infra + ArgoCD + secrets K8s
│
├── terraform/
│   ├── main.tf                 ← orquestra os 9 módulos
│   ├── variables.tf
│   ├── providers.tf
│   ├── backend.tf              ← backend S3 com use_lockfile (sem bucket hardcoded)
│   ├── outputs.tf
│   ├── versions.tf
│   ├── terraform.tfvars.example
│   └── modules/
│       ├── networking/         ← VPC, subnets, IGW, NAT, route tables
│       ├── eks/                ← Cluster + Node Group (LabRole)
│       ├── rds/                ← 3× PostgreSQL + Secrets Manager
│       ├── elasticache/        ← Redis (VPC privada)
│       ├── dynamodb/           ← ToggleMasterAnalytics
│       ├── sqs/                ← fila principal + DLQ
│       ├── ecr/                ← 5 repos com lifecycle (untagged: 1 dia, tagged: 10 versões)
│       ├── argocd/             ← Helm chart + 6 Application CRDs (5 serviços + ingress)
│       └── k8s-bootstrap/      ← namespaces, secrets de DB, ConfigMap central,
│                                  ingress-nginx (LoadBalancer), metrics-server,
│                                  secret aws-credentials (SQS/DynamoDB)
│
├── services/
│   ├── auth-service/           (Go 1.25, pgx v5.9.2)
│   ├── flag-service/           (Python 3.11, Flask + gunicorn)
│   ├── targeting-service/      (Python 3.11, Flask + gunicorn)
│   ├── evaluation-service/     (Go 1.25, aws-sdk-go-v2)
│   └── analytics-service/      (Python 3.11, Flask + gunicorn + boto3)
│
├── gitops/base/
│   ├── auth/
│   ├── flag/
│   ├── targeting/
│   ├── evaluation/
│   ├── analytics/
│   └── ingress/togglemaster-ingress.yaml
│
└── docs/
    └── RELATORIO_ENTREGA.md
```

---

## Como executar

### Pré-requisitos

- Conta AWS com a `LabRole` (AWS Academy) ou conta pessoal com permissões de admin
- Repositório no GitHub (fork ou clone)
- Para acesso local ao cluster: `aws-cli 2.x`, `kubectl 1.30+`

---

### Opção A — via GitHub Actions (recomendada)

#### 1. Configurar secrets do repositório

**Settings → Secrets and variables → Actions → New repository secret:**

| Secret | Valor |
|---|---|
| `AWS_ACCESS_KEY_ID` | do painel AWS Academy |
| `AWS_SECRET_ACCESS_KEY` | do painel AWS Academy |
| `AWS_SESSION_TOKEN` | do painel AWS Academy |
| `TF_STATE_BUCKET` | nome único do bucket S3 (ex: `togglemaster-tfstate-rm12345`) |

> As credenciais da Academy expiram a cada sessão. Quando expirar, atualize os 3 secrets e rode o workflow `apply` novamente — ele atualiza os secrets K8s dentro do cluster automaticamente.

#### 2. Ativar permissões de escrita

**Settings → Actions → General → Workflow permissions → Read and write permissions**

Sem isso, o step `update-gitops` não consegue commitar a nova tag.

#### 3. (Opcional) Criar Environments com aprovação manual

**Settings → Environments → New environment:** crie `production` e `production-destroy`. Adicione-se como required reviewer para exigir confirmação antes de apply ou destroy.

#### 4. Provisionar a infraestrutura

**Actions → Terraform Infra → Run workflow:**

| Ação | O que faz |
|---|---|
| `plan` | Mostra o que vai ser criado/modificado |
| `apply` | Provisiona tudo (~20 min na primeira vez) |
| `destroy` | Remove todos os recursos AWS |

O `apply` provisiona em sequência: VPC → EKS → RDS/Redis/DynamoDB/SQS → ingress-nginx → secrets K8s → ArgoCD → Applications. Ao final, o log do job `post-apply-check` mostra o DNS do NLB e os comandos para acessar o ArgoCD.

#### 5. Acessar o ArgoCD

Configure o kubectl localmente:

```bash
aws eks update-kubeconfig --region us-east-1 --name togglemaster-eks-prod
```

Exponha o ArgoCD via LoadBalancer (cria um segundo NLB):

```bash
kubectl -n argocd patch svc argocd-server -p '{"spec":{"type":"LoadBalancer"}}'

# Aguardar ~2 min e pegar o DNS
kubectl -n argocd get svc argocd-server \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# Senha do admin
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

Acesse `http://<DNS-ARGOCD>` com usuário `admin`. Você verá 6 Applications: os 5 serviços + `togglemaster-ingress`.

#### 6. Disparar o CI/CD

Faça qualquer commit em `services/` e push na main. O pipeline detecta qual serviço mudou e roda só os jobs necessários. Para forçar todos os 5:

**Actions → CI/CD Microservices → Run workflow → `force_all: true`**

---

### Opção B — local (depuração)

Instale também: `terraform >= 1.10`, `helm 3.x`.

```bash
# 1. Criar o bucket S3 para o tfstate (uma vez)
BUCKET="togglemaster-tfstate-$RANDOM"
aws s3api create-bucket --bucket "$BUCKET" --region us-east-1
aws s3api put-bucket-versioning --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled

# 2. Inicializar o backend
cd terraform
terraform init \
  -backend-config="bucket=$BUCKET" \
  -backend-config="key=togglemaster/fase3/terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="encrypt=true" \
  -backend-config="use_lockfile=true"

# 3. Configurar tfvars
cp terraform.tfvars.example terraform.tfvars
# Edite gitops_repo_url com a URL do seu repo

# 4. Aplicar
terraform plan
terraform apply

# 5. Destruir quando terminar (sempre faça isso antes)
kubectl delete applications --all -n argocd --timeout=120s
sleep 30
terraform destroy
```

---

## Workflows do GitHub Actions

### `terraform-infra.yml`

Responsável por toda a infraestrutura AWS. Além de provisionar, o job `post-apply-check` cria automaticamente o secret `aws-credentials` em `evaluation-namespace` e `analytics-namespace` — necessário para que esses serviços chamem SQS e DynamoDB na AWS Academy (que não tem Instance Profile nos nodes EKS).

### `cicd-services.yml`

Um único workflow com 7 jobs:

- `detect-changes` — decide quais serviços foram modificados via paths-filter
- `ci-auth`, `ci-flag`, `ci-targeting`, `ci-evaluation`, `ci-analytics` — rodam em paralelo; serviços não modificados aparecem como Skipped
- `ci-summary` — agrega o resultado; use como required check no branch protection

### `_reusable-cicd.yml`

Motor chamado pelos 5 jobs de serviço. Estágios em ordem:

1. `build-test` — compilação e testes unitários
2. `lint` — golangci-lint (Go) ou flake8 (Python)
3. `security` — Trivy fs (SCA) + gosec ou bandit (SAST); bloqueia em CRITICAL/HIGH
4. `docker` — build + Trivy image scan + push no ECR com tag `v1.0.0-<sha-7>`
5. `update-gitops` — atualiza a tag em `gitops/base/<serviço>/deployment.yaml` com retry de 5 tentativas

---

## DevSecOps — o pipeline

| Estágio | Ferramenta | Bloqueia em |
|---|---|---|
| Build & Unit Test | `go test` / `pytest` | erro de build ou teste |
| Lint | `golangci-lint v1.64.8` / `flake8` | erro de lint |
| SCA (dependências) | Trivy modo `fs` | CRITICAL |
| SAST (código) | `gosec` (Go) / `bandit -lll` (Python) | HIGH |
| Container scan | Trivy modo `image` | CRITICAL |
| Push ECR | tag `v1.0.0-<sha-7>` | — |
| Update GitOps | sed + commit com retry | — |

**Para demonstrar o bloqueio**, troque `crypto/sha256` por `crypto/sha1` no `evaluation-service/evaluator.go` e abra um PR. O job `security` falha com gosec G401. Reverter faz o pipeline passar.

---

## Testando os microsserviços

Após o `apply`, pegue o DNS do NLB:

```bash
NLB=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
```

**No PowerShell:**

```powershell
$NLB = kubectl -n ingress-nginx get svc ingress-nginx-controller `
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

### Health checks

```bash
curl http://$NLB/auth/health
curl http://$NLB/flags/health
curl http://$NLB/targeting/health
curl http://$NLB/evaluation/health
curl http://$NLB/analytics/health
```

### Fluxo completo

```bash
# 1. Criar API key
MASTER=$(kubectl -n auth-namespace get secret auth-extra-secret \
  -o jsonpath='{.data.MASTER_KEY}' | base64 -d)

API_KEY=$(curl -s -X POST http://$NLB/auth/admin/keys \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $MASTER" \
  -d '{"name":"demo"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['key'])")

# 2. Criar feature flag
curl -s -X POST http://$NLB/flags/flags \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"name":"dark-mode","is_enabled":true}'

# 3. Criar regra de segmentação (50% dos usuários)
curl -s -X POST http://$NLB/targeting/rules \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"flag_name":"dark-mode","is_enabled":true,"rules":{"type":"PERCENTAGE","value":50}}'

# 4. Avaliar para usuários
curl -s "http://$NLB/evaluation/evaluate?user_id=user-1&flag_name=dark-mode"
curl -s "http://$NLB/evaluation/evaluate?user_id=user-2&flag_name=dark-mode"

# 5. Verificar eventos no DynamoDB (aguardar ~10s para o analytics processar a fila)
sleep 10
aws dynamodb scan --table-name ToggleMasterAnalytics --region us-east-1 --max-items 5
```

**No PowerShell:** substitua `curl` por `Invoke-RestMethod`, `| base64 -d` por `| % { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_)) }`, e `python3 -c` por `| ConvertFrom-Json | Select-Object -ExpandProperty key`.

---
