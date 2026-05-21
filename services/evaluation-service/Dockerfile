# =============================================================================
# Dockerfile — evaluation-service
#
# Go 1.25 padronizado entre todos os serviços Go do projeto (pgx v5.9.2
# do auth-service exige Go >= 1.25; alinhamos os dois para simplificar
# o CI e ter uma única versão de toolchain no pipeline).
# =============================================================================

# Stage 1: Build
FROM golang:1.23-alpine AS builder

WORKDIR /app

RUN apk add --no-cache git

# Cache de dependências
COPY go.mod ./
RUN go mod download || true
COPY . .
# go.sum é gerado/atualizado aqui — evita versioná-lo no repo
RUN go mod tidy

# Build estático
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags="-s -w" -o evaluation-service .

# Stage 2: Runtime
FROM alpine:3.20

RUN apk add --no-cache ca-certificates \
 && addgroup -S app && adduser -S -G app app

WORKDIR /app
COPY --from=builder /app/evaluation-service .
RUN chown -R app:app /app
USER app

EXPOSE 8004

CMD ["./evaluation-service"]

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:8004/health || exit 1
