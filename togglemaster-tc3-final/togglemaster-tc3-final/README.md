# ToggleMaster — Tech Challenge Fase 3

Sistema de feature flags (5 microsserviços) implantado em **AWS EKS** via
**Terraform**, com pipeline **DevSecOps** no GitHub Actions e entrega
contínua via **ArgoCD** (GitOps).

> **Contexto:** este projeto cumpre os requisitos do *PosTech — Tech Challenge
> Fase 3*, executado em ambiente AWS Academy usando a **LabRole** existente
> (Opção A do enunciado).

---

## Arquitetura

```
┌──────────────────────────────────────────────────────────────────────┐
│                            AWS Account                                │
│                                                                      │
│  ┌──── Terraform (S3 backend) ────┐                                  │
│  │                                │                                  │
│  │  VPC 10.0.0.0/16                                                  │
│  │   ├─ public subnets  (2 AZs) ─── IGW ── Internet                  │
│  │   └─ private subnets (2 AZs) ─── NAT                              │
│  │        │                                                          │
│  │        ├─ EKS Cluster (LabRole) ──── ArgoCD ─── monitora ──┐      │
│  │        │     └─ Node Group t3.medium                       │      │
│  │        ├─ RDS PostgreSQL x3   (auth, flag, targeting)      │      │
│  │        ├─ ElastiCache Redis                                │      │
│  │        ├─ DynamoDB (ToggleMasterAnalytics)                 │      │
│  │        └─ SQS (togglemaster-queue)                         │      │
│  │                                                            │      │
│  │  ECR x5 (togglemaster-auth, -flag, -targeting, -evaluation,│      │
│  │          -analytics)                                       │      │
│  │  Secrets Manager (credenciais geradas pelo TF)             │      │
│  └────────────────────────────────────────────────────────────┘      │
│                                                              ▼      │
│                                                  ┌──── GitHub ────┐ │
│                                                  │  - código      │ │
│  ◀──── CI faz push da imagem para ECR ───────────│  - terraform   │ │
│  ◀──── CI atualiza tag em gitops/base/...        │  - gitops/     │ │
│                                                  │  - workflows   │ │
│                                                  └────────────────┘ │
└──────────────────────────────────────────────────────────────────────┘
```

## Estrutura do repositório

```
.
├── terraform/                  ← IaC modularizado
│   ├── main.tf                 ← orquestra os módulos
│   ├── variables.tf
│   ├── providers.tf
│   ├── backend.tf              ← backend S3 com use_lockfile
│   ├── outputs.tf
│   ├── versions.tf
│   ├── terraform.tfvars.example
│   └── modules/
│       ├── networking/         ← VPC, subnets, IGW, NAT, route tables
│       ├── eks/                ← cluster + node group (LabRole)
│       ├── rds/                ← 3 PostgreSQL + Secrets Manager
│       ├── elasticache/        ← Redis
│       ├── dynamodb/           ← ToggleMasterAnalytics
│       ├── sqs/                ← fila principal + DLQ
│       ├── ecr/                ← 5 repositórios
│       ├── argocd/             ← Helm + Application CRDs
│       └── k8s-bootstrap/      ← namespaces, secrets, configmaps, metrics-server
│
├── services/                   ← código dos 5 microsserviços
│   ├── auth-service/           (Go)
│   ├── flag-service/           (Python)
│   ├── targeting-service/      (Python)
│   ├── evaluation-service/     (Go)
│   └── analytics-service/      (Python)
│
├── gitops/                     ← manifestos K8s monitorados pelo ArgoCD
│   ├── base/
│   │   ├── auth/{deployment,service,job-init-db}.yaml
│   │   ├── flag/{deployment,service,job-init-db}.yaml
│   │   ├── targeting/{deployment,service,job-init-db}.yaml
│   │   ├── evaluation/{deployment,service,hpa}.yaml
│   │   ├── analytics/{deployment,service,hpa}.yaml
│   │   └── ingress/togglemaster-ingress.yaml
│   └── argocd/                 ← (opcional) Application manifests aplicáveis fora do TF
│
├── .github/workflows/
│   ├── _reusable-cicd.yml      ← workflow reutilizável (lógica central)
│   ├── ci-auth.yml
│   ├── ci-flag.yml
│   ├── ci-targeting.yml
│   ├── ci-evaluation.yml
│   └── ci-analytics.yml
│
└── docs/
    ├── RELATORIO_ENTREGA.md    ← relatório (.pdf via export)
    └── arquitetura.md
```

## Como executar

### 1. Pré-requisitos

| Ferramenta | Versão mínima |
|---|---|
| Terraform | 1.10 (para `use_lockfile`) |
| AWS CLI | 2.x configurado com credenciais do AWS Academy |
| kubectl | 1.30 |
| Helm | 3.x |

### 2. Criar o bucket S3 do backend (UMA VEZ)

```bash
BUCKET=togglemaster-tfstate-$RANDOM
aws s3api create-bucket --bucket $BUCKET --region us-east-1
aws s3api put-bucket-versioning --bucket $BUCKET \
    --versioning-configuration Status=Enabled
echo "Atualize terraform/backend.tf com bucket=$BUCKET"
```

### 3. Provisionar tudo

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edite terraform.tfvars (principalmente gitops_repo_url)

terraform init
terraform plan
terraform apply
```

A primeira execução leva ~20 minutos (EKS demora ~15min sozinho).

### 4. Configurar kubectl + acessar o ArgoCD

```bash
aws eks update-kubeconfig --region us-east-1 \
    --name $(terraform output -raw cluster_name)

# Senha inicial do admin do ArgoCD:
kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' | base64 -d ; echo

# UI do ArgoCD:
kubectl -n argocd port-forward svc/argocd-server 8080:443
# Acesse https://localhost:8080  (usuário: admin)
```

### 5. Configurar secrets do GitHub Actions

Em **Settings → Secrets and variables → Actions** do seu repositório, crie:

| Secret | Conteúdo |
|---|---|
| `AWS_ACCESS_KEY_ID` | da AWS Academy |
| `AWS_SECRET_ACCESS_KEY` | da AWS Academy |
| `AWS_SESSION_TOKEN` | da AWS Academy (token temporário) |
| `GITOPS_TOKEN` | (opcional) PAT se o GitOps for outro repo |

A partir daí, qualquer `git push` em `services/<nome>-service/**` dispara
o pipeline daquele serviço, e o ArgoCD aplica a nova versão.

## DevSecOps — o que o pipeline garante

Para **cada um dos 5 serviços**, em todo PR e push na main:

| Estágio | Ferramenta | Bloqueia em |
|---|---|---|
| Build & Unit Test | `go test` / `pytest` | erro de compilação ou teste |
| Lint | `golangci-lint` / `flake8` | erros de estilo |
| SCA (deps) | `Trivy fs` | qualquer **CRITICAL** |
| SAST (código) | `gosec` / `bandit` | severity **HIGH+** |
| Container Scan | `Trivy image` | qualquer **CRITICAL** |
| Push ECR | tag = `v1.0.0-<sha curto>` | — |
| GitOps update | `sed` + commit | — |

O ArgoCD detecta o commit em `gitops/base/<service>/deployment.yaml` e
sincroniza a nova versão automaticamente (sync policy `automated`,
`selfHeal=true`, `prune=true`).

## Decisões de design relevantes

Veja [`docs/RELATORIO_ENTREGA.md`](docs/RELATORIO_ENTREGA.md) para detalhes
das decisões e desafios encontrados.

Pontos rápidos:

- **Sem Infisical.** Substituído por `random_password` + AWS Secrets Manager.
  Funciona no AWS Academy sem precisar criar IAM, e remove dependência externa.
- **Senhas nunca aparecem no Git.** São geradas pelo TF e injetadas no cluster
  como `Secret` K8s. O Git só armazena referências (`secretKeyRef`).
- **Workflow reutilizável**: 1 arquivo central com a lógica + 5 wrappers finos
  por serviço. Atende ao requisito "pipeline para cada microsserviço" sem
  duplicação.
- **GitOps puro**: o CI NUNCA faz `kubectl apply`. Ele só faz push do bump
  de tag. O ArgoCD é o único agente que mexe no cluster.
