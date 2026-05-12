output "namespaces" {
  value = { for k, v in kubernetes_namespace.app : k => v.metadata[0].name }
}
