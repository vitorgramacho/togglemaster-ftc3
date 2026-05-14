# ToggleMaster — Tech Challenge Fase 3

Sistema de feature flags com **5 microsserviços** (auth, flag, targeting,
evaluation, analytics) implantado em **AWS EKS** via **Terraform**, com
pipeline **DevSecOps** no GitHub Actions e entrega contínua via **ArgoCD**
(GitOps).

> **Contexto:** projeto do *PosTech — Tech Challenge Fase 3*, executado
> no **AWS Academy** usando a `LabRole` existente (Opção A do enunciado).
> O Terraform não cria nenhuma IAM Role/Policy.

---

## Sumário

1. [Arquitetura](#arquitetura)
2. [Estrutura do repositório](#estrutura-do-repositório)
3. [Como executar](#como-executar) — escolha entre fluxo automatizado (workflows) ou local
4. [Workflows do GitHub Actions](#workflows-do-github-actions)
5. [DevSecOps — o pipeline](#devsecops--o-pipeline)
6. [Demonstração (vídeo)](#demonstração-vídeo)
7. [Troubleshooting](#troubleshooting)
8. [Decisões de design](#decisões-de-design)

---

## Arquitetura

```
┌──────────────────────────────────────────────────────────────────────┐
│                            AWS Account                                │
│                                                                       │
│  ┌──── Terraform (S3 backend + use_lockfile) ────┐                   │
│  │                                                                    │
│  │  VPC 10.0.0.0/16                                                   │
│  │   ├─ public  subnets (2 AZs) ─── IGW ── Internet                  │
│  │   └─ private subnets (2 AZs) ─── NAT                              │
│  │        │                                                           │
│  │        ├─ EKS Cluster (LabRole) ── ArgoCD (Helm) ── monitora ──┐  │
│  │        │     └─ Node Group t3.medium                            │  │
│  │        ├─ RDS PostgreSQL x3   (auth, flag, targeting)           │  │
│  │        ├─ ElastiCache Redis                                     │  │
│  │        ├─ DynamoDB (ToggleMasterAnalytics)                      │  │
│  │        └─ SQS  (togglemaster-queue + DLQ)                       │  │
│  │                                                                  │  │
│  │  ECR x5  (togglemaster-{auth,flag,targeting,evaluation,         │  │
│  │           analytics})                                            │  │
│  │  Secrets Manager (credenciais geradas pelo TF)                  │  │
│  └─────────────────────────────────────────────────────────────────┘  │
│                                                                ▼      │
│                                                  ┌──── GitHub ────┐  │
│           ◀── CI: push image → ECR ──────────────│  - código      │  │
│           ◀── CI: bump tag em gitops/base/ ──────│  - terraform/  │  │
│                                                  │  - gitops/     │  │
│                                                  │  - workflows/  │  │
│                                                  └────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
```

**Fluxo end-to-end:**

1. Dev faz push em `services/<nome>-service/**`
2. Workflow `cicd-services.yml` roda os 5 estágios DevSecOps **só** para
   o serviço modificado (5 jobs paralelos com paths-filter)
3. CI publica a imagem no ECR e faz commit em
   `gitops/base/<serviço>/deployment.yaml` atualizando a tag
4. ArgoCD detecta o commit e sincroniza a nova versão no EKS
   (sync policy `automated`, `selfHeal: true`, `prune: true`)

---

## Estrutura do repositório

```
.
├── .github/workflows/
│   ├── _reusable-cicd.yml      ← motor reutilizável dos pipelines
│   ├── cicd-services.yml       ← UM workflow com 5 jobs paralelos
│   └── terraform-infra.yml     ← provisiona infra + bootstrap ArgoCD
│
├── terraform/                  ← IaC modularizado (29 .tf)
│   ├── main.tf                 ← orquestra os 9 módulos
│   ├── variables.tf
│   ├── providers.tf            ← aws / kubernetes / helm
│   ├── backend.tf              ← backend S3 com use_lockfile
│   ├── outputs.tf
│   ├── versions.tf
│   ├── terraform.tfvars.example
│   └── modules/
│       ├── networking/         ← VPC, subnets, IGW, NAT, route tables
│       ├── eks/                ← Cluster + Node Group (LabRole)
│       ├── rds/                ← 3× PostgreSQL + Secrets Manager
│       ├── elasticache/        ← Redis (sem TLS, em VPC privada)
│       ├── dynamodb/           ← Tabela ToggleMasterAnalytics
│       ├── sqs/                ← Fila principal + DLQ
│       ├── ecr/                ← 5 repositórios com lifecycle
│       ├── argocd/             ← Helm chart + 5 Application CRDs
│       └── k8s-bootstrap/      ← namespaces, Secret de DB, ConfigMap,
│                                  metrics-server
│
├── services/                   ← código dos microsserviços
│   ├── auth-service/           (Go 1.25, pgx v5.9.2)
│   ├── flag-service/           (Python 3.11, Flask)
│   ├── targeting-service/      (Python 3.11, Flask)
│   ├── evaluation-service/     (Go 1.25, aws-sdk-go-v2)
│   └── analytics-service/      (Python 3.11, Flask)
│
├── gitops/base/                ← manifestos K8s monitorados pelo ArgoCD
│   ├── auth/{deployment,service,job-init-db}.yaml
│   ├── flag/{deployment,service,job-init-db}.yaml
│   ├── targeting/{deployment,service,job-init-db}.yaml
│   ├── evaluation/{deployment,service,hpa}.yaml
│   ├── analytics/{deployment,service,hpa}.yaml
│   └── ingress/togglemaster-ingress.yaml
│
└── docs/
    └── RELATORIO_ENTREGA.md    ← relatório (exporte para PDF)
```

---

## Como executar

Há **dois caminhos**: o automatizado pelo GitHub Actions (recomendado e
exigido pelo desafio) e o local (útil para depurar). Pode usar ambos.

### Pré-requisitos comuns

- Conta AWS com a `LabRole` (AWS Academy) ou conta pessoal
- Repositório forkeado/clonado no GitHub

Para a opção **B (local)** apenas:

| Ferramenta | Versão |
|---|---|
| Terraform | ≥ 1.10 (para `use_lockfile`) |
| AWS CLI | 2.x |
| kubectl | 1.30 |
| Helm | 3.x |

---

### 🔵 Opção A — execução via GitHub Actions (recomendada)

Tudo é provisionado, validado e atualizado pelos workflows. Você não
precisa instalar nada na sua máquina além de um navegador.

#### Passo 1 — Configurar os secrets do repositório

Vá em **Settings → Secrets and variables → Actions** e crie:

| Secret | Conteúdo | Usado por |
|---|---|---|
| `AWS_ACCESS_KEY_ID` | da AWS Academy | ambos workflows |
| `AWS_SECRET_ACCESS_KEY` | da AWS Academy | ambos |
| `AWS_SESSION_TOKEN` | token temporário da Academy | ambos |
| `TF_STATE_BUCKET` | nome único do bucket S3 para o tfstate (ex.: `togglemaster-tfstate-fiap-rm123`) | `terraform-infra` |
| `GITOPS_TOKEN` | (opcional) PAT só se o repo GitOps for **outro** repositório | `cicd-services` |

> No AWS Academy as credenciais expiram a cada sessão. Quando expirar,
> atualize os 3 primeiros secrets.

#### Passo 2 — Configurar permissões do `GITHUB_TOKEN`

**Settings → Actions → General → Workflow permissions** → marque
**"Read and write permissions"**. Sem isso, o passo `update-gitops` do
CI não consegue commitar o bump de imagem.

#### Passo 3 — (Opcional, mas recomendado) Criar GitHub Environments

**Settings → Environments → New environment**. Crie:

- `production` — para o `terraform apply`
- `production-destroy` — para o `terraform destroy`

Em cada um, marque-se como **required reviewer** se quiser confirmação
manual antes de aplicar ou destruir.

#### Passo 4 — Provisionar a infraestrutura

Aba **Actions → Terraform Infra → Run workflow**:

| Quando | Escolha `action:` |
|---|---|
| Quero ver o que vai mudar | **`plan`** |
| Quero criar/atualizar a infra | **`apply`** |
| Quero destruir tudo | **`destroy`** |

Na primeira execução com `apply`:

- O job `terraform-plan` cria automaticamente o bucket S3 do tfstate se
  ele ainda não existir (versioning + SSE habilitados)
- O job `terraform-apply` provisiona VPC → EKS → RDS/Redis/Dynamo/SQS →
  K8s bootstrap → ArgoCD → 5 Applications
- O job `post-apply-check` faz `kubectl wait` no ArgoCD e imprime
  instruções de acesso no log

**Tempo total da primeira execução: ~20 minutos** (EKS sozinho leva ~15).

#### Passo 5 — Acessar a UI do ArgoCD

Você precisa de `aws-cli` + `kubectl` localmente apenas para o
port-forward. Pegue o nome do cluster do output do workflow ou rode:

```bash
aws eks update-kubeconfig --region us-east-1 --name togglemaster-eks-prod

# Senha inicial do admin:
kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' | base64 -d ; echo

# Port-forward em background:
kubectl -n argocd port-forward svc/argocd-server 8080:443 &
```

Abra <https://localhost:8080> — usuário `admin`, senha do comando acima.
Você verá os 5 Applications (`auth-service`, `flag-service`,
`targeting-service`, `evaluation-service`, `analytics-service`).

#### Passo 6 — Validar o pipeline DevSecOps

Faça um commit qualquer em `services/auth-service/main.go` (mesmo um
comentário) e empurre na main. Você verá em **Actions**:

1. Um run único de **CI/CD Microservices**
2. Job `auth` rodando — os outros 4 marcados como **Skipped**
3. Estágios `build-test → lint → security → docker → update-gitops`
4. No último passo, um commit automático em `gitops/base/auth/deployment.yaml`
5. O ArgoCD detecta e sincroniza em segundos

---

### 🟢 Opção B — execução local (depuração)

Use só quando o workflow não estiver disponível ou quiser depurar.

#### Passo 1 — Criar o bucket S3 do tfstate (uma vez)

```bash
BUCKET=togglemaster-tfstate-fiap-$RANDOM
aws s3api create-bucket --bucket "$BUCKET" --region us-east-1
aws s3api put-bucket-versioning --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$BUCKET" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
echo "Atualize terraform/backend.tf com bucket=$BUCKET"
```

Edite `terraform/backend.tf` e troque o valor de `bucket`:

```hcl
backend "s3" {
  bucket       = "togglemaster-tfstate-fiap-12345"   # ← seu valor
  key          = "togglemaster/fase3/terraform.tfstate"
  region       = "us-east-1"
  encrypt      = true
  use_lockfile = true
}
```

#### Passo 2 — Configurar tfvars

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edite `terraform.tfvars` — o campo importante é `gitops_repo_url`:

```hcl
gitops_repo_url = "https://github.com/SEU-USUARIO/togglemaster-tc3.git"
```

#### Passo 3 — Aplicar

```bash
terraform init
terraform plan
terraform apply              # ~20 min
```

#### Passo 4 — Acessar o ArgoCD

Mesmos comandos da Opção A, passo 5.

#### Passo 5 — Destruir quando terminar

```bash
# Limpe Applications antes para o destroy do node group não travar
kubectl delete applications --all -n argocd --timeout=120s
sleep 30
terraform destroy
```

---

## Workflows do GitHub Actions

Apenas **3 arquivos** em `.github/workflows/`:

### `terraform-infra.yml` — Provisiona toda a infra

| Trigger | O que faz |
|---|---|
| `workflow_dispatch` com `action: plan` | Mostra o que vai mudar |
| `workflow_dispatch` com `action: apply` | Provisiona ou atualiza tudo |
| `workflow_dispatch` com `action: destroy` | Limpa Applications e destrói |
| `pull_request` em `terraform/**` | Roda `plan` e comenta no PR |
| `push` em `terraform/**` na main | Roda `plan` e, se houver mudanças, `apply` |

Jobs internos:

1. **`terraform-plan`** — cria bucket S3 se preciso, `fmt -check`, `init`,
   `validate`, `plan` com `-detailed-exitcode`, salva tfplan como artifact
2. **`terraform-apply`** — usa Environment `production`, aplica o plan
3. **`post-apply-check`** — `aws eks update-kubeconfig`, `kubectl wait`
   no ArgoCD, lista Applications, mascara a senha do admin nos logs
4. **`terraform-destroy`** — Environment `production-destroy`, limpa
   Applications, roda `destroy`

### `cicd-services.yml` — UM workflow, 5 serviços, 1 run

| Trigger | O que faz |
|---|---|
| `pull_request` em `services/**` ou `gitops/base/**` | Roda só os jobs dos serviços modificados |
| `push` em `services/**` ou `gitops/base/**` na main | Idem + push para ECR + bump no GitOps |
| `workflow_dispatch` (`force_all: true`) | Roda os 5 |

Jobs internos (7 no total):

1. **`detect-changes`** — `dorny/paths-filter@v3` decide quais serviços
   mudaram (e força todos se o `_reusable-cicd.yml` foi alterado)
2. **`ci-auth`** — chama o reusable para o auth-service (Go)
3. **`ci-flag`** — chama o reusable para o flag-service (Python)
4. **`ci-targeting`** — chama o reusable para o targeting-service (Python)
5. **`ci-evaluation`** — chama o reusable para o evaluation-service (Go)
6. **`ci-analytics`** — chama o reusable para o analytics-service (Python)
7. **`ci-summary`** — agrega resultado; é o único job que você deve
   marcar como **required check** no branch protection

Os 5 jobs de serviço rodam **em paralelo** (todos dependem apenas de
`detect-changes`). Cada um tem um `if:` que verifica se houve mudança
naquele serviço ou se `force_all` está ativo — se não houve, aparece
como **Skipped**.

### `_reusable-cicd.yml` — Motor de CI/CD

Chamado pelo `cicd-services.yml`. Estágios:

1. **`build-test`** — `go mod tidy && go build && go test` ou `pytest`
2. **`lint`** — `golangci-lint` (Go) ou `flake8` (Python)
3. **`security`** — Trivy fs (SCA) + gosec (Go) ou bandit (Python).
   Falha se algum reportar **CRITICAL**/**HIGH**
4. **`docker`** — só em push na main. Build, Trivy image scan, push no
   ECR com tag `v1.0.0-<sha curto>`
5. **`update-gitops`** — `sed` na linha `image:` do
   `gitops/base/<serviço>/deployment.yaml`, commit e push na main

---

## DevSecOps — o pipeline

Para **cada um dos 5 serviços**, em PR e push na main:

| Estágio | Ferramenta | Bloqueia em |
|---|---|---|
| Build & Unit Test | `go test` / `pytest` | Erro de compilação ou teste |
| Lint | `golangci-lint` / `flake8` | Erros de estilo |
| SCA (dependências) | `Trivy fs` | qualquer **CRITICAL** |
| SAST (código) | `gosec` / `bandit` | severity **HIGH+** |
| Container scan | `Trivy image` | qualquer **CRITICAL** |
| Push ECR | tag = `v1.0.0-<sha-7>` | — |
| Update GitOps | `sed` + commit em `main` | — |

### Como demonstrar o bloqueio

Edite `services/evaluation-service/evaluator.go` e troque o
`crypto/sha256` por `crypto/sha1` (alterando o import e a função):

```go
import "crypto/sha1"
// ...
func getDeterministicBucket(input string) int {
    hash := sha1.Sum([]byte(input))   // ← gosec G401 (HIGH)
    val := binary.BigEndian.Uint32(hash[:4])
    return int(val % 100)
}
```

Faça PR para `main`. O job `security` do `evaluation` falha com **G401**.
Reverter o commit faz o pipeline passar.

---

## Demonstração (vídeo)

Roteiro sugerido (≤ 20 min):

1. **IaC** (3 min) — Mostre `terraform-infra.yml` no Actions com o plan
   + apply rodando. Console AWS: VPCs, RDS, EKS criados pelo TF.
2. **DevSecOps falhando** (4 min) — Faça o commit do SHA-1 acima. PR
   ficando vermelho no job `security`. Mostre o log do gosec apontando
   G401.
3. **DevSecOps passando** (2 min) — Reverter o commit. Pipeline verde.
4. **GitOps update** (3 min) — Mostre o passo `update-gitops` fazendo
   commit em `gitops/base/evaluation/deployment.yaml` com a nova tag.
5. **ArgoCD sync** (4 min) — UI em `localhost:8080`. App
   `evaluation-service` ficando `OutOfSync` por alguns segundos e
   voltando para `Synced + Healthy`. Mostre os 5 Applications saudáveis.
6. **Conclusão** (2 min) — Print da estimativa de custos da AWS.

---

## Troubleshooting

### O workflow `update-gitops` falha com "permission denied"

Vá em **Settings → Actions → General → Workflow permissions** e marque
**"Read and write permissions"**. Salve e re-rode.

### O `terraform apply` reclama de "InvalidClientTokenId"

O `AWS_SESSION_TOKEN` da Academy expirou. Atualize os 3 secrets
(`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`) e
roda de novo.

### Os pods entram em `CrashLoopBackOff` no primeiro deploy

Provavelmente a tag de imagem em `gitops/base/<serviço>/deployment.yaml`
ainda é o placeholder `busybox:latest`. Faça um commit em
`services/<serviço>/main.go` (qualquer comentário) e o pipeline atualiza
a tag para o que está no ECR.

### O `terraform destroy` fica preso por horas no node group

O ArgoCD está recriando pods em loop via `selfHeal`. Antes de qualquer
`destroy`, sempre rode:

```bash
kubectl delete applications --all -n argocd --timeout=120s
sleep 30
```

(O job `terraform-destroy` do workflow já faz isso automaticamente.)

### O ArgoCD não acha o repo GitOps

Se o repositório for **privado**, registre as credenciais no ArgoCD:

```bash
kubectl -n argocd create secret generic repo-togglemaster \
    --from-literal=type=git \
    --from-literal=url=https://github.com/SEU-USUARIO/togglemaster-tc3.git \
    --from-literal=username=<seu-usuário> \
    --from-literal=password=<seu-PAT> \
    -o yaml --dry-run=client | \
  kubectl label -f - --local -o yaml \
    argocd.argoproj.io/secret-type=repository | kubectl apply -f -
```

Repos públicos não precisam disso.

---

## Decisões de design

Detalhes completos em [`docs/RELATORIO_ENTREGA.md`](docs/RELATORIO_ENTREGA.md).

Pontos rápidos:

- **Sem Infisical.** Substituído por `random_password` + AWS Secrets
  Manager. Funciona na AWS Academy sem criar IAM, remove dependência
  externa, e as senhas são auditáveis pelo console.
- **Nenhuma credencial no Git.** Senhas são geradas pelo Terraform e
  injetadas como `Secret` K8s. O Git só guarda `secretKeyRef`.
- **`pgx v5.9.2` → Go 1.25** em todos os serviços Go (auth e evaluation),
  alinhado com o requisito do driver.
- **`crypto/sha256` em vez de `crypto/sha1`** no evaluation-service para
  o bucketing determinístico (uso não-criptográfico, mas evita G401).
- **`tls.Config{InsecureSkipVerify: true}` removido** do evaluation.
  ElastiCache não tem TLS habilitado e o tráfego fica dentro da VPC.
- **Servers HTTP com `ReadHeaderTimeout` etc.** em auth e evaluation
  (mitiga gosec G114 / Slowloris).
- **`aws-sdk-go-v2`** no evaluation (v1 está EOL desde 31/jul/2025).
- **GitOps puro.** O CI nunca faz `kubectl apply` — só atualiza tag no
  Git. O ArgoCD é o único agente que muda o cluster.
- **Workflow consolidado.** Um arquivo `cicd-services.yml` substitui
  cinco `ci-<service>.yml`. 5 jobs paralelos com paths-filter — única
  run no Actions UI, até 5 jobs lado-a-lado, jobs não modificados
  aparecem como Skipped.
