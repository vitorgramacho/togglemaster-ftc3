# Terraform — ToggleMaster Fase 3

Infraestrutura como Código (AWS), modularizada em 9 módulos.

## Estrutura

```
terraform/
├── backend.tf              # backend S3 com use_lockfile
├── main.tf                 # orquestra os módulos
├── providers.tf            # aws / kubernetes / helm
├── variables.tf
├── versions.tf
├── outputs.tf
├── terraform.tfvars.example
└── modules/
    ├── networking/   ← VPC, subnets, IGW, NAT, route tables
    ├── eks/          ← Cluster EKS + Node Group (LabRole)
    ├── rds/          ← 3 PostgreSQL + Secrets Manager
    ├── elasticache/  ← Redis
    ├── dynamodb/     ← ToggleMasterAnalytics
    ├── sqs/          ← Fila principal + DLQ
    ├── ecr/          ← 5 repositórios com lifecycle
    ├── argocd/       ← Helm chart + Application CRDs
    └── k8s-bootstrap/← Namespaces, Secrets, ConfigMaps, metrics-server
```

## Quickstart

```bash
# 1) Crie o bucket S3 do tfstate (uma vez)
aws s3api create-bucket --bucket togglemaster-tfstate-MEUID --region us-east-1
aws s3api put-bucket-versioning --bucket togglemaster-tfstate-MEUID \
    --versioning-configuration Status=Enabled

# 2) Ajuste o bucket em backend.tf

# 3) Copie e edite as variáveis
cp terraform.tfvars.example terraform.tfvars
# edite gitops_repo_url

# 4) Provisione
terraform init
terraform plan
terraform apply
```

Tempo total esperado: ~20 min (EKS é o gargalo).

## Variáveis principais

| Variável | Default | Descrição |
|---|---|---|
| `aws_region` | `us-east-1` | região de tudo |
| `project` | `togglemaster` | prefixo de nomes |
| `cluster_name` | `togglemaster-eks-prod` | nome do EKS |
| `kubernetes_version` | `1.30` | versão do control plane |
| `services` | 5 | lista de serviços (ECR + namespaces) |
| `db_services` | `[auth, flag, targeting]` | serviços com RDS dedicado |
| `gitops_repo_url` | — | URL HTTPS do repo monitorado pelo ArgoCD |
| `expose_argocd_lb` | `false` | true = LoadBalancer; false = port-forward |

## Outputs úteis

```bash
terraform output cluster_name
terraform output ecr_repository_urls
terraform output rds_endpoints
terraform output redis_url
terraform output argocd_port_forward_command
terraform output argocd_initial_admin_password_command
```

## Destruir

```bash
terraform destroy
```

⚠ O ArgoCD instala recursos no cluster que NÃO estão no state do Terraform
(os Deployments/Services criados a partir do `gitops/base/`). Antes de
`terraform destroy`, é boa prática rodar:

```bash
kubectl delete applications -n argocd --all
```

Caso contrário o destroy do node group pode demorar (precisa do drain
dos pods).

## AWS Academy

- O Terraform **não cria** roles ou policies de IAM.
- Tudo que precisa de IAM (cluster, node group) aponta para a `LabRole`
  via `data.aws_iam_role.labrole` no `main.tf` raiz.
- Em ambiente pessoal, basta substituir essas referências por módulos
  que criem as roles necessárias.
