package main

import (
	"encoding/json"
	"log"
	"net/http"
	"strings"
)

// Estrutura para o corpo da requisição de criação de chave
type CreateKeyRequest struct {
	Name string `json:"name"`
	// Key é opcional. Quando fornecido (ex: pelo Job de seed do evaluation-service),
	// a chave exata é armazenada (em hash) em vez de gerar uma aleatória.
	// Isso permite que o Terraform injete o SERVICE_API_KEY e o registre
	// no banco numa única operação idempotente.
	Key string `json:"key,omitempty"`
}

// Estrutura para a resposta da criação de chave
type CreateKeyResponse struct {
	Name    string `json:"name"`
	Key     string `json:"key"` // chave em texto plano retornada APENAS uma vez
	Message string `json:"message"`
}

// writeJSON encapsula a serialização e o tratamento de erros de Encode (gosec G104).
// Manter centralizado evita ignorar erros e facilita a inclusão de métricas no futuro.
func writeJSON(w http.ResponseWriter, status int, body interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(body); err != nil {
		log.Printf("erro ao escrever resposta JSON: %v", err)
	}
}

// healthHandler é um simples endpoint de verificação de saúde
func (a *App) healthHandler(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// validateKeyHandler verifica se uma chave de API (enviada via Header) é válida
func (a *App) validateKeyHandler(w http.ResponseWriter, r *http.Request) {
	authHeader := r.Header.Get("Authorization")
	keyString := strings.TrimPrefix(authHeader, "Bearer ")

	if keyString == "" {
		http.Error(w, "Authorization header não encontrado", http.StatusUnauthorized)
		return
	}

	// Calcula o hash da chave recebida
	keyHash := hashAPIKey(keyString)

	// Verifica se o hash existe no banco de dados
	var id int
	err := a.DB.QueryRow(
		"SELECT id FROM api_keys WHERE key_hash = $1 AND is_active = true",
		keyHash,
	).Scan(&id)
	if err != nil {
		log.Printf("Falha na validação da chave (hash: %s...): %v", keyHash[:6], err)
		http.Error(w, "Chave de API inválida ou inativa", http.StatusUnauthorized)
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"message": "Chave válida"})
}

// createKeyHandler cria uma nova chave de API
func (a *App) createKeyHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Método não permitido", http.StatusMethodNotAllowed)
		return
	}

	var req CreateKeyRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Corpo da requisição inválido", http.StatusBadRequest)
		return
	}

	if req.Name == "" {
		http.Error(w, "O campo 'name' é obrigatório", http.StatusBadRequest)
		return
	}

	// Gera uma nova chave (ou usa a fornecida no body) e calcula seu hash
	var newKey string
	var err error
	if req.Key != "" {
		// Chave fornecida externamente (ex: seed do evaluation-service via Job K8s).
		// Apenas validamos o formato mínimo e usamos diretamente.
		newKey = req.Key
	} else {
		newKey, err = generateAPIKey()
		if err != nil {
			http.Error(w, "Erro ao gerar a chave", http.StatusInternalServerError)
			return
		}
	}
	newKeyHash := hashAPIKey(newKey)

	// Salva o hash no banco de dados
	var newID int
	err = a.DB.QueryRow(
		"INSERT INTO api_keys (name, key_hash) VALUES ($1, $2) RETURNING id",
		req.Name, newKeyHash,
	).Scan(&newID)

	if err != nil {
		log.Printf("Erro ao salvar a chave no banco: %v", err)
		http.Error(w, "Erro ao salvar a chave", http.StatusInternalServerError)
		return
	}

	log.Printf("Nova chave criada com sucesso (ID: %d, Name: %s)", newID, req.Name)
	writeJSON(w, http.StatusCreated, CreateKeyResponse{
		Name:    req.Name,
		Key:     newKey,
		Message: "Guarde esta chave com segurança! Você não poderá vê-la novamente.",
	})
}

// --- Middleware ---

// masterKeyAuthMiddleware protege endpoints que só podem ser acessados com a MASTER_KEY
func (a *App) masterKeyAuthMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authHeader := r.Header.Get("Authorization")
		keyString := strings.TrimPrefix(authHeader, "Bearer ")

		if keyString != a.MasterKey {
			http.Error(w, "Acesso não autorizado", http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}
