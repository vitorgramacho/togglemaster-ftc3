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
