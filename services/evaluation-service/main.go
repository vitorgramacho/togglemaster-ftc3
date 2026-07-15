package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"github.com/joho/godotenv"
	"github.com/redis/go-redis/v9"

	// Fase 4 — instrumentação OpenTelemetry
	"evaluation-service/telemetry"
)

// Contexto global para o Redis
var ctx = context.Background()

// App struct para injeção de dependência
type App struct {
	RedisClient         *redis.Client
	SqsClient           *sqs.Client
	SqsQueueURL         string
	HttpClient          *http.Client
	FlagServiceURL      string
	TargetingServiceURL string
}

func main() {
	_ = godotenv.Load()

	// --- Configuração ---
	port := os.Getenv("PORT")
	if port == "" {
		port = "8004"
	}

	redisURL := os.Getenv("REDIS_URL")
	if redisURL == "" {
		log.Fatal("REDIS_URL deve ser definida (ex: redis://host:6379)")
	}

	flagSvcURL := os.Getenv("FLAG_SERVICE_URL")
	if flagSvcURL == "" {
		log.Fatal("FLAG_SERVICE_URL deve ser definida")
	}

	targetingSvcURL := os.Getenv("TARGETING_SERVICE_URL")
	if targetingSvcURL == "" {
		log.Fatal("TARGETING_SERVICE_URL deve ser definida")
	}

	sqsQueueURL := os.Getenv("AWS_SQS_URL")
	awsRegion := os.Getenv("AWS_REGION")
	if sqsQueueURL == "" {
		log.Println("Atenção: AWS_SQS_URL não definida. Eventos não serão enviados.")
	}
	if awsRegion == "" && sqsQueueURL != "" {
		log.Fatal("AWS_REGION deve ser definida para usar SQS")
	}

	// =========================================================================
	// OpenTelemetry — Fase 4
	// -----------------------------------------------------------------------
	// O evaluation-service é o serviço CRÍTICO do cenário descrito no
	// enunciado ("começou a falhar silenciosamente"). Daí a importância
	// extra das métricas/traces aqui.
	// =========================================================================
	otelCtx, otelCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer otelCancel()
	shutdownOtel, err := telemetry.Init(otelCtx, "evaluation-service")
	if err != nil {
		log.Printf("[warn] OpenTelemetry falhou ao inicializar: %v", err)
		shutdownOtel = func(context.Context) error { return nil }
	}

	opt, err := redis.ParseURL(redisURL)
	if err != nil {
		log.Fatalf("Não foi possível parsear a URL do Redis: %v", err)
	}
	rdb := redis.NewClient(opt)

	if _, err := rdb.Ping(ctx).Result(); err != nil {
		log.Fatalf("Não foi possível conectar ao Redis: %v", err)
	}
	log.Println("Conectado ao Redis com sucesso!")

	var sqsClient *sqs.Client
	if sqsQueueURL != "" {
		cfgOpts := []func(*config.LoadOptions) error{
			config.WithRegion(awsRegion),
		}

		accessKey := os.Getenv("AWS_ACCESS_KEY_ID")
		secretKey := os.Getenv("AWS_SECRET_ACCESS_KEY")
		sessionToken := os.Getenv("AWS_SESSION_TOKEN")

		if accessKey != "" && secretKey != "" {
			cfgOpts = append(cfgOpts,
				config.WithCredentialsProvider(
					credentials.NewStaticCredentialsProvider(accessKey, secretKey, sessionToken),
				),
			)
			log.Println("SQS: usando credenciais estáticas dos env vars.")
		}

		localstackEndpoint := os.Getenv("LOCALSTACK_ENDPOINT")

		awsCfg, err := config.LoadDefaultConfig(context.Background(), cfgOpts...)
		if err != nil {
			log.Fatalf("Não foi possível criar config AWS: %v", err)
		}

		sqsClient = sqs.NewFromConfig(awsCfg, func(o *sqs.Options) {
			if localstackEndpoint != "" {
				o.BaseEndpoint = aws.String(localstackEndpoint)
				log.Printf("SQS configurado para LocalStack: %s", localstackEndpoint)
			}
		})
		log.Println("Cliente SQS (v2) inicializado com sucesso.")
	}

	httpClient := &http.Client{
		Timeout: 5 * time.Second,
		// Embrulha o Transport com otelhttp -> chamadas para flag-service e
		// targeting-service injetam o header `traceparent` automaticamente,
		// ligando o trace fim-a-fim. SEM isso, o Service Map fica desconexo.
		Transport: telemetry.WrapTransport(http.DefaultTransport),
	}

	// Cria a instância da App
	app := &App{
		RedisClient:         rdb,
		SqsClient:           sqsClient,
		SqsQueueURL:         sqsQueueURL,
		HttpClient:          httpClient,
		FlagServiceURL:      flagSvcURL,
		TargetingServiceURL: targetingSvcURL,
	}

	// --- Rotas ---
	mux := http.NewServeMux()
	mux.HandleFunc("/health", app.healthHandler)
	mux.HandleFunc("/evaluate", app.evaluationHandler)

	// Embrulha o mux com otelhttp -> spans em CADA request
	instrumentedHandler := telemetry.WrapHandler(mux, "evaluation-service")

	server := &http.Server{
		Addr:              ":" + port,
		Handler:           instrumentedHandler,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	// Graceful shutdown — exporta spans em buffer ao receber SIGTERM
	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
		<-sig
		log.Println("Sinal recebido, encerrando...")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
		_ = shutdownOtel(shutdownCtx)
	}()

	log.Printf("Serviço de Avaliação (Go) rodando na porta %s", port)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}
