# Tech Challenge — Fase 3 — Relatório de Entrega

## Participantes

> _Preencher com os nomes do grupo_

- Nome 1 — RM XXXXX
- Nome 2 — RM XXXXX
- Nome 3 — RM XXXXX

## Links

| Recurso | Link |
|---|---|
| Repositório principal | `https://github.com/USUARIO/togglemaster-tc3` |
| Vídeo de demonstração (≤ 20 min) | _adicionar URL_ |
| Documentação | `README.md` na raiz do repositório |

---

## 1. Resumo da entrega

O projeto migra o ToggleMaster (5 microsserviços construídos na Fase 2)
para um modelo totalmente declarativo:

- **Toda a infraestrutura AWS** é provisionada por Terraform modular,
  com estado remoto em S3 e *lock* via `use_lockfile`.
- **Os pipelines de CI/CD** rodam em GitHub Actions com 5 estágios obrigatórios
  (build/test → lint → SCA/SAST → docker build+scan → ECR push) e bloqueiam
  em vulnerabilidades CRITICAL.
- **A entrega ao cluster** é feita por GitOps com ArgoCD. O pipeline NUNCA
  faz `kubectl apply`: ele só atualiza a tag de imagem em
  `gitops/base/<servico>/deployment.yaml` e o ArgoCD sincroniza sozinho.

---

## 2. Mapeamento dos requisitos do enunciado → entregáveis

### Requisito 1 — Infraestrutura como Código (Terraform)

| Item | Onde está |
|---|---|
| VPC, subnets pub/priv, IGW, route tables | `terraform/modules/networking/` |
| EKS Cluster + Node Group (usando LabRole) | `terraform/modules/eks/` |
| 3 RDS PostgreSQL | `terraform/modules/rds/` |
| ElastiCache Redis | `terraform/modules/elasticache/` |
| DynamoDB `ToggleMasterAnalytics` | `terraform/modules/dynamodb/` |
| Fila SQS | `terraform/modules/sqs/` |
| 5 repositórios ECR | `terraform/modules/ecr/` |
| Backend S3 + `use_lockfile` | `terraform/backend.tf` |
| Importação da LabRole via data source | `terraform/main.tf` (`data.aws_iam_role.labrole`) |

### Requisito 2 — Pipeline CI / DevSecOps

| Estágio | Implementação | Bloqueio |
|---|---|---|
| Build & Unit Test | `go test` / `pytest` | Erro de build ou teste |
| Linter | `golangci-lint` / `flake8` | Erro de lint |
| SCA | Trivy `fs` | `severity: CRITICAL` com `exit-code: 1` |
| SAST | `gosec` / `bandit` | severity HIGH (mais alto reportado) |
| Docker build + image scan | Trivy `image` | `severity: CRITICAL` com `exit-code: 1` |
| Push ECR | tag = `v1.0.0-<7chars-sha>` | — |
| Trigger | `pull_request` + `push` na `main` | — |

Arquivo central: `.github/workflows/_reusable-cicd.yml` — chamado por
`ci-auth.yml`, `ci-flag.yml`, `ci-targeting.yml`, `ci-evaluation.yml`,
`ci-analytics.yml`.

### Requisito 3 — CD & GitOps

| Item | Implementação |
|---|---|
| Repositório de GitOps | pasta `gitops/base/` no mesmo monorepo (pode ser separado se quiser; basta apontar `gitops_repo_url`) |
| Instalação do ArgoCD | `terraform/modules/argocd/` (Helm chart oficial) |
| Atualização automática da tag | job `update-gitops` no workflow reutilizável (`sed` + commit) |
| Sync automático | `Application` CRD com `syncPolicy.automated.{prune,selfHeal}` |

---

## 3. Desafios encontrados e decisões tomadas

### 3.1. AWS Academy + IAM

A versão anterior tinha referências a `data.aws_iam_role.labrole` mas
não modularizava nada. **Decisão:** centralizamos o uso da LabRole no
`main.tf` raiz e passamos o ARN como variável para o módulo `eks/`. Isso
mantém os módulos reutilizáveis (não acoplados ao AWS Academy) e atende
o "Opção A" do enunciado.

### 3.2. Segredos: substituição do Infisical

A entrega anterior dependia de Infisical (provider externo, exige conta
e duas variáveis `infisical_client_id/_secret`). **Decisão:** removemos
essa dependência inteira. Agora:

1. `random_password` gera senhas no apply.
2. Cada senha é gravada no **AWS Secrets Manager** (auditável).
3. Em paralelo, o módulo `k8s-bootstrap` injeta as mesmas credenciais
   como `Secret` Kubernetes na *namespace* do serviço — referenciado nos
   manifests via `secretKeyRef`.

Resultado: nenhuma senha no Git, zero dependência externa, funciona no
AWS Academy.

### 3.3. Bug do `DATABASE_URL`

Os apps (`auth/main.go`, `flag/app.py`, `targeting/app.py`) leem
`DATABASE_URL` como connection string completa, mas os manifestos
antigos só injetavam `DB_HOST` + `DB_PASSWORD` separados → todos os
pods entravam em CrashLoopBackOff.

**Decisão:** o módulo `rds/` agora exporta `connection_urls` (já
montadas em `postgres://user:pass@host:port/db?sslmode=require`) e o
`k8s-bootstrap` injeta isso direto no `Secret` com chave `DATABASE_URL`,
exatamente como o app espera. Sem mudar uma linha de código de aplicação.

### 3.4. Bug do `REDIS_URL` no evaluation-service

O `evaluation-service/main.go` faz `redis.ParseURL(redisURL)`, que exige
o esquema `redis://host:port`. O manifesto antigo passava apenas o
hostname → o parse falhava no startup.

Além disso, o código ativava TLS com `InsecureSkipVerify: true`, mas o
cluster Redis foi criado sem `transit_encryption_enabled` → handshake
TLS falharia.

**Decisão:** o módulo `elasticache/` agora exporta `redis_url` já
formatada, e os manifestos consomem essa string pronta via
`configMapKeyRef`. (Se o time mantiver o bloco TLS no Go, sugiro
removê-lo ou habilitar `transit_encryption_enabled` no Terraform.)

### 3.5. Bug do `auth-job.yaml`

A versão anterior tinha 3 defeitos em um único arquivo:
1. Faltava `---` entre Job e ConfigMap (manifest inválido).
2. `config_map` em vez de `configMap` (typo).
3. Secret key `DB_PASS_0` em vez de `password_0` que era o que o TF criava.

Reescrito em `gitops/base/auth/job-init-db.yaml` com YAML válido,
referência ao Secret central `togglemaster-db-secret`, e `restartPolicy: OnFailure`
+ `backoffLimit: 4`.

### 3.6. Account ID hardcoded nas imagens

`191468900606.dkr.ecr.us-east-1.amazonaws.com/...` estava direto nos
manifestos — quebra a cada nova sessão do AWS Academy (Account ID muda).

**Decisão:** a linha `image: ...` agora é **substituída pelo CI** no
job `update-gitops`, com a URI completa (`<registry>/<repo>:<tag>`)
calculada dinamicamente a partir de `aws-actions/amazon-ecr-login`.
Os manifestos no Git têm um placeholder (`busybox:latest`) só para
serem válidos antes do primeiro deploy.

### 3.7. Ingress com FQDN em `backend.service.name`

Ingress nativo do Kubernetes só aceita o nome curto de um Service no
**mesmo namespace** do Ingress.

**Decisão:** criamos o namespace `togglemaster-edge` com 5 Services do
tipo `ExternalName` (apontando para o FQDN real de cada microsserviço),
e o Ingress fica nesse namespace, roteando para esses backends locais.
Solução padrão e suportada por `ingress-nginx`.

### 3.8. CI fazia `kubectl rollout restart` — anti-GitOps

A versão anterior misturava CD com CI (o workflow fazia `kubectl rollout
restart` ao final). Isso causa conflito com o ArgoCD (que faz drift
detection e tentaria reverter).

**Decisão:** retiramos qualquer interação direta com o cluster do CI.
O CI agora só fala com ECR e com o repo Git. O ArgoCD é o único agente
com permissão de modificar o cluster.

### 3.9. Trivy não bloqueava

A versão anterior tinha `exit-code: '0'` em todos os jobs Trivy — o
pipeline **nunca** falhava por vulnerabilidade, contrariando a "Regra de
Bloqueio" do desafio.

**Decisão:** ajustado para `exit-code: '1'` + `severity: 'CRITICAL'` +
`ignore-unfixed: true` (para não falhar por algo que não tem fix
disponível ainda).

### 3.10. Modularização do Terraform

A versão anterior era um único `main.tf` de ~300 linhas. **Decisão:**
quebramos em 9 módulos (`networking`, `eks`, `rds`, `elasticache`,
`dynamodb`, `sqs`, `ecr`, `argocd`, `k8s-bootstrap`), cada um com
`main.tf` / `variables.tf` / `outputs.tf` próprios. O `main.tf` raiz só
orquestra.

---

## 4. Estimativa de custos AWS

> _Anexar print do AWS Pricing Calculator antes da entrega final._
>
> Estimativa aproximada (us-east-1, janela de 1 mês, ambiente sempre ligado):
>
> | Recurso | Quantidade | Custo mensal aproximado |
> |---|---|---|
> | EKS Control Plane | 1 | ~ $72,00 |
> | EC2 Worker Nodes (t3.medium) | 2 | ~ $61,00 |
> | RDS db.t3.micro PostgreSQL | 3 | ~ $36,00 |
> | ElastiCache cache.t3.micro | 1 | ~ $12,50 |
> | DynamoDB (PAY_PER_REQUEST) | 1 | ~ $1,00 (com tráfego baixo) |
> | SQS | 1 | < $0,50 |
> | NAT Gateway | 1 | ~ $32,00 |
> | EBS (gp3, 60GB total) | — | ~ $5,00 |
> | **Total estimado** | | **~ $220,00/mês** |
>
> Para reduzir custos em demonstração, basta destruir tudo após cada
> sessão de aula: `terraform destroy`.

---

## 5. Como reproduzir a demo do vídeo

1. **IaC** — `terraform plan && terraform apply`. Recursos visíveis no console.
2. **DevSecOps falhando** — adicionar `import os; os.system("...")` no
   `flag-service/app.py` para gerar finding HIGH no bandit. PR fica vermelho.
3. **DevSecOps passando** — revert do commit, PR fica verde.
4. **GitOps update** — merge na main; o job `update-gitops` faz commit
   atualizando a tag no `gitops/base/flag/deployment.yaml`.
5. **ArgoCD sincronizando** — abrir `https://localhost:8080` (após
   `kubectl port-forward`); ver as 5 Applications. A app `flag-service`
   fica "OutOfSync" por alguns segundos, depois "Synced" + "Healthy".
