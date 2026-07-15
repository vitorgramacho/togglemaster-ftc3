module auth-service

go 1.25.0

require (
	github.com/golang-jwt/jwt/v4 v4.5.0
	github.com/jackc/pgx/v5 v5.9.2
	github.com/joho/godotenv v1.5.1

	// ===== OpenTelemetry (Fase 4) =====
	github.com/prometheus/client_golang v1.20.5
	go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp v0.55.0
	go.opentelemetry.io/otel v1.30.0
	go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp v1.30.0
	go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp v1.30.0
	go.opentelemetry.io/otel/exporters/prometheus v0.52.0
	go.opentelemetry.io/otel/sdk v1.30.0
	go.opentelemetry.io/otel/sdk/metric v1.30.0
)

require (
	github.com/jackc/pgpassfile v1.0.0 // indirect
	github.com/jackc/pgservicefile v0.0.0-20240606120523-5a60cdf6a761 // indirect
	github.com/jackc/puddle/v2 v2.2.2 // indirect
	golang.org/x/sync v0.17.0 // indirect
	golang.org/x/text v0.29.0 // indirect
)

// ═══════════════════════════════════════════════════════════════════════════
// Correção de segurança (Fase 4) — CVE-2026-33186
// ---------------------------------------------------------------------------
// CVE-2026-33186 (CVSS 9.1): authorization bypass no google.golang.org/grpc
// em versões < v1.79.3. O gRPC entra APENAS como dependência TRANSITIVA do SDK
// OpenTelemetry (o exporter otlptracehttp importa grpc via internal/otlpconfig,
// mesmo usando só HTTP — ver open-telemetry/opentelemetry-go#2579). A aplicação
// NÃO sobe servidor gRPC nem usa authz, então não é explorável — mas o Trivy
// escaneia o binário e bloqueia o CI ao achar a versão vulnerável.
//
// Nenhuma release do OTel SDK traz grpc >= v1.79.3 por padrão ainda (o OTel
// v1.38 usa grpc v1.75.1). Por isso usamos `replace` (não só `require`): ele
// FORÇA a versão corrigida em TODO o grafo, inclusive nas referências
// transitivas, garantindo que o binário final não embarque a versão vulnerável.
// É seguro porque não chamamos a API do gRPC diretamente (só os exporters HTTP
// do OTel a usam internamente, e a API é retrocompatível dentro da v1.x).
// Ref.: https://avd.aquasec.com/nvd/cve-2026-33186
// ═══════════════════════════════════════════════════════════════════════════
require google.golang.org/grpc v1.79.3

replace google.golang.org/grpc => google.golang.org/grpc v1.79.3
