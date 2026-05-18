package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"github.com/joho/godotenv"
	"github.com/redis/go-redis/v9"
)

// Contexto global para o Redis - Comentário para alterar a tag da imagem 
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
	_ = godotenv.Load() // Carrega .env para dev local

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

	// SQS é opcional no dev local, mas obrigatório em prod
	sqsQueueURL := os.Getenv("AWS_SQS_URL")
	awsRegion := os.Getenv("AWS_REGION")
	if sqsQueueURL == "" {
		log.Println("Atenção: AWS_SQS_URL não definida. Eventos não serão enviados.")
	}
	if awsRegion == "" && sqsQueueURL != "" {
		log.Fatal("AWS_REGION deve ser definida para usar SQS")
	}

	// --- Inicializa Clientes ---

	// 1. Cliente Redis
	//
	// SECURITY (gosec G402): a versão anterior forçava
	//     tls.Config{InsecureSkipVerify: true}
	// o que é uma vulnerabilidade HIGH (CWE-295). Removemos completamente.
	//
	// O cluster ElastiCache criado pelo Terraform NÃO tem transit_encryption
	// habilitado, então a conexão é em texto puro dentro da VPC.
	// Caso futuramente o cluster seja recriado COM TLS, a URL deve passar a
	// usar o esquema `rediss://`, e o cliente fará TLS com verificação
	// completa do certificado (sem InsecureSkipVerify).
	opt, err := redis.ParseURL(redisURL)
	if err != nil {
		log.Fatalf("Não foi possível parsear a URL do Redis: %v", err)
	}
	rdb := redis.NewClient(opt)

	if _, err := rdb.Ping(ctx).Result(); err != nil {
		log.Fatalf("Não foi possível conectar ao Redis: %v", err)
	}
	log.Println("Conectado ao Redis com sucesso!")

	// 2. Cliente SQS — migrado para aws-sdk-go-v2 (v1 está EOL desde 31/jul/2025).
	var sqsClient *sqs.Client
	if sqsQueueURL != "" {
		cfgOpts := []func(*config.LoadOptions) error{
			config.WithRegion(awsRegion),
		}

		// LocalStack: se LOCALSTACK_ENDPOINT estiver setado, usamos endpoint custom
		// via BaseEndpoint (modo correto na v2; EndpointResolver foi deprecado).
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

	// 3. Cliente HTTP (com timeout)
	httpClient := &http.Client{
		Timeout: 5 * time.Second,
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

	// SECURITY (gosec G114): servidor HTTP com timeouts explícitos.
	server := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	log.Printf("Serviço de Avaliação (Go) rodando na porta %s", port)
	if err := server.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}
