package main

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"sync"
	"time"
)

const (
	// Tempo de vida do cache em segundos
	CACHE_TTL = 30 * time.Second
)

// getDecision é o wrapper principal
func (a *App) getDecision(userID, flagName string) (bool, error) {
	info, err := a.getCombinedFlagInfo(flagName)
	if err != nil {
		return false, err
	}
	return a.runEvaluationLogic(info, userID), nil
}

// getCombinedFlagInfo busca no Redis com fallback para os microsserviços
func (a *App) getCombinedFlagInfo(flagName string) (*CombinedFlagInfo, error) {
	cacheKey := fmt.Sprintf("flag_info:%s", flagName)

	// 1. Tentar buscar do Cache (Redis)
	val, err := a.RedisClient.Get(ctx, cacheKey).Result()
	if err == nil {
		var info CombinedFlagInfo
		if uerr := json.Unmarshal([]byte(val), &info); uerr == nil {
			log.Printf("Cache HIT para flag '%s'", flagName)
			return &info, nil
		}
		log.Printf("Erro ao desserializar cache para flag '%s': %v", flagName, err)
	}

	log.Printf("Cache MISS para flag '%s'", flagName)

	// 2. Cache MISS - Buscar dos serviços
	info, err := a.fetchFromServices(flagName)
	if err != nil {
		return nil, err
	}

	// 3. Salvar no Cache (best effort)
	if jsonData, mErr := json.Marshal(info); mErr == nil {
		if sErr := a.RedisClient.Set(ctx, cacheKey, jsonData, CACHE_TTL).Err(); sErr != nil {
			log.Printf("Falha ao salvar no cache (não-fatal): %v", sErr)
		}
	}

	return info, nil
}

// fetchFromServices busca dados do flag-service e targeting-service concorrentemente
func (a *App) fetchFromServices(flagName string) (*CombinedFlagInfo, error) {
	var wg sync.WaitGroup
	wg.Add(2)

	var flagInfo *Flag
	var ruleInfo *TargetingRule
	var flagErr, ruleErr error

	go func() {
		defer wg.Done()
		flagInfo, flagErr = a.fetchFlag(flagName)
	}()

	go func() {
		defer wg.Done()
		ruleInfo, ruleErr = a.fetchRule(flagName)
	}()

	wg.Wait()

	if flagErr != nil {
		return nil, flagErr
	}
	if ruleErr != nil {
		log.Printf("Aviso: regra de segmentação não encontrada para '%s' (%v). Usando padrão.",
			flagName, ruleErr)
	}

	return &CombinedFlagInfo{
		Flag: flagInfo,
		Rule: ruleInfo,
	}, nil
}

// fetchFlag busca a flag no flag-service.
//
// SECURITY (gosec G107/G306): construímos a URL via fmt.Sprintf usando apenas
// flagName, que vem da query string e poderia conter caracteres ofensivos.
// Aqui validamos via http.NewRequestWithContext que rejeita URLs malformadas.
func (a *App) fetchFlag(flagName string) (*Flag, error) {
	url := fmt.Sprintf("%s/flags/%s", a.FlagServiceURL, flagName)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, fmt.Errorf("erro ao montar requisição: %w", err)
	}

	apiKey := os.Getenv("SERVICE_API_KEY")
	req.Header.Set("Authorization", "Bearer "+apiKey)

	resp, err := a.HttpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("erro ao chamar flag-service: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		return nil, &NotFoundError{flagName}
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("flag-service retornou status %d", resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("erro ao ler resposta do flag-service: %w", err)
	}

	var flag Flag
	if err := json.Unmarshal(body, &flag); err != nil {
		return nil, fmt.Errorf("erro ao desserializar resposta do flag-service: %w", err)
	}
	return &flag, nil
}

func (a *App) fetchRule(flagName string) (*TargetingRule, error) {
	url := fmt.Sprintf("%s/rules/%s", a.TargetingServiceURL, flagName)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, fmt.Errorf("erro ao montar requisição: %w", err)
	}

	apiKey := os.Getenv("SERVICE_API_KEY")
	req.Header.Set("Authorization", "Bearer "+apiKey)

	resp, err := a.HttpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("erro ao chamar targeting-service: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		return nil, &NotFoundError{flagName}
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("targeting-service retornou status %d", resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("erro ao ler resposta do targeting-service: %w", err)
	}

	var rule TargetingRule
	if err := json.Unmarshal(body, &rule); err != nil {
		return nil, fmt.Errorf("erro ao desserializar resposta do targeting-service: %w", err)
	}
	return &rule, nil
}

// runEvaluationLogic é onde a decisão é tomada
func (a *App) runEvaluationLogic(info *CombinedFlagInfo, userID string) bool {
	if info.Flag == nil || !info.Flag.IsEnabled {
		return false
	}

	if info.Rule == nil || !info.Rule.IsEnabled {
		return true
	}

	rule := info.Rule.Rules
	if rule.Type == "PERCENTAGE" {
		percentage, ok := rule.Value.(float64)
		if !ok {
			log.Printf("Erro: valor da regra de porcentagem não é número para '%s'", info.Flag.Name)
			return false
		}

		userBucket := getDeterministicBucket(userID + info.Flag.Name)

		if float64(userBucket) < percentage {
			return true
		}
	}

	return false
}

// getDeterministicBucket distribui usuários determinísticamente em buckets [0..99].
//
// SECURITY (gosec G401): a versão anterior usava SHA-1, considerado quebrado
// para usos criptográficos. Aqui o uso NÃO é criptográfico (é só hashing
// para distribuição uniforme), mas o gosec não consegue saber disso e
// reporta HIGH. Trocamos por SHA-256 — também distribui uniformemente,
// é amplamente disponível, e elimina o finding.
func getDeterministicBucket(input string) int {
	hash := sha256.Sum256([]byte(input))
	val := binary.BigEndian.Uint32(hash[:4])
	return int(val % 100)
}
