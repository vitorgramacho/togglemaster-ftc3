package main

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
)

type EvaluationResponse struct {
	FlagName string `json:"flag_name"`
	UserID   string `json:"user_id"`
	Result   bool   `json:"result"`
}

// writeJSON centraliza serialização + tratamento do erro do Encode (gosec G104).
func writeJSON(w http.ResponseWriter, status int, body interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(body); err != nil {
		log.Printf("erro ao escrever resposta JSON: %v", err)
	}
}

func (a *App) healthHandler(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (a *App) evaluationHandler(w http.ResponseWriter, r *http.Request) {
	userID := r.URL.Query().Get("user_id")
	flagName := r.URL.Query().Get("flag_name")

	if userID == "" || flagName == "" {
		writeJSON(w, http.StatusBadRequest,
			map[string]string{"error": "user_id e flag_name são obrigatórios"})
		return
	}

	// Obter a decisão (lógica de cache/serviço está em evaluator.go)
	result, err := a.getDecision(userID, flagName)
	if err != nil {
		// Se for "não encontrado", retornamos 'false' (fail-closed)
		var nfe *NotFoundError
		if errors.As(err, &nfe) {
			result = false
		} else {
			log.Printf("Erro ao avaliar flag '%s': %v", flagName, err)
			writeJSON(w, http.StatusBadGateway,
				map[string]string{"error": "Erro interno ao avaliar a flag"})
			return
		}
	}

	// Envia evento para SQS assincronamente (não bloqueia a resposta).
	go a.sendEvaluationEvent(userID, flagName, result)

	writeJSON(w, http.StatusOK, EvaluationResponse{
		FlagName: flagName,
		UserID:   userID,
		Result:   result,
	})
}
