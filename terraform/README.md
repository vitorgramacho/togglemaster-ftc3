# Terraform — ToggleMaster Fase 4

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



