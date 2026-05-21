output "namespaces" {
  value = { for k, v in kubernetes_namespace.app : k => v.metadata[0].name }
}

output "ingress_nginx_service_name" {
  description = "Nome do Service do ingress-nginx (para buscar o DNS do NLB via kubectl)."
  value       = "ingress-nginx-controller"
}
