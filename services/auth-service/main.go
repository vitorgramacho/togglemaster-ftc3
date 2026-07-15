package main

import (
	"context"
	"database/sql"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/joho/godotenv"

	// Fase 4 — instrumentação OpenTelemetry
	"auth-service/telemetry"
)

type App struct {
	DB        *sql.DB
	MasterKey string
}

func main() {
	_ = godotenv.Load()

	port := os.Getenv("PORT")
	if port == "" {
		port = "8001"
	}

	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		log.Fatal("DATABASE_URL deve ser definida")
	}

	masterKey := os.Getenv("MASTER_KEY")
	if masterKey == "" {
		log.Fatal("MASTER_KEY deve ser definida")
	}

	// =========================================================================
	// OpenTelemetry — Fase 4
	// -----------------------------------------------------------------------
	// Inicializa traces+metrics. Note que isto roda ANTES de qualquer rota
	// para que o middleware otelhttp seja registrado a tempo. O `shutdown`
	// retornado garante que os spans em buffer sejam exportados quando o pod
	// receber SIGTERM (rolling update / scale-down do K8s).
	// =========================================================================
	otelCtx, otelCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer otelCancel()
	shutdownOtel, err := telemetry.Init(otelCtx, "auth-service")
	if err != nil {
		// Falha de telemetria NÃO derruba o app — log e segue
		log.Printf("[warn] OpenTelemetry falhou ao inicializar: %v", err)
		shutdownOtel = func(context.Context) error { return nil }
	}

	db, err := connectDB(databaseURL)
	if err != nil {
		log.Fatalf("Não foi possível conectar ao banco de dados: %v", err)
	}
	defer db.Close()

	app := &App{
		DB:        db,
		MasterKey: masterKey,
	}

	// --- Rotas da API ---
	mux := http.NewServeMux()
	mux.HandleFunc("/health", app.healthHandler)
	mux.HandleFunc("/validate", app.validateKeyHandler)
	mux.Handle("/admin/keys", app.masterKeyAuthMiddleware(http.HandlerFunc(app.createKeyHandler)))

	// Embrulha o mux com otelhttp -> cada request gera um span automaticamente
	instrumentedHandler := telemetry.WrapHandler(mux, "auth-service")

	server := &http.Server{
		Addr:              ":" + port,
		Handler:           instrumentedHandler,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	// Graceful shutdown: ouve SIGTERM (K8s rolling update) e dá tempo para
	// o OTel exportar os últimos spans.
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

	log.Printf("Serviço de Autenticação (Go) rodando na porta %s", port)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}

// connectDB inicializa e testa a conexão com o PostgreSQL
func connectDB(databaseURL string) (*sql.DB, error) {
	db, err := sql.Open("pgx", databaseURL)
	if err != nil {
		return nil, err
	}

	if err = db.Ping(); err != nil {
		return nil, err
	}

	log.Println("Conectado ao PostgreSQL com sucesso!")
	return db, nil
}
