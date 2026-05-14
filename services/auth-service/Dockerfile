# =============================================================================
# Dockerfile — auth-service
#
# Por que Go 1.25:
#   pgx v5.9.2 exige Go >= 1.25 no go.mod.
#   Fonte: https://pkg.go.dev/github.com/jackc/pgx/v5
#
# Decisões para reduzir vulnerabilidades reportadas pelo Trivy:
#  - Imagem base 'alpine:3.20' (anteriormente 3.19): menos CVEs HIGH/CRITICAL.
#  - Builder em 'golang:1.25-alpine' em vez de 'golang:1.24.0' Debian-based.
#  - Removida instalação de 'curl' no builder (não usado em runtime).
#  - 'go mod tidy' garante go.sum consistente sem precisar versioná-lo.
#  - Usuário não-root no runtime.
# =============================================================================

# Stage 1: Build
FROM golang:1.25-alpine AS builder

WORKDIR /app

RUN apk add --no-cache git

# Cache de dependências
COPY go.mod ./
RUN go mod download || true
COPY . .
RUN go mod tidy

# Build estático
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags="-s -w" -o auth-service .

# Stage 2: Runtime
FROM alpine:3.20

RUN apk add --no-cache ca-certificates \
 && addgroup -S app && adduser -S -G app app

WORKDIR /app
COPY --from=builder /app/auth-service .
RUN chown -R app:app /app
USER app

EXPOSE 8001

CMD ["./auth-service"]

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:8001/health || exit 1
