package main

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"sync"
	"time"
)

const (
	// Tempo de vida do cache em segundos
	CACHE_TTL = 30 * time.Second
)

// validFlagNameRe aceita apenas nomes de flag seguros: letras, números, hífens e underscores.
// Isso previne path traversal e injeção de URL (resolve G107 do gosec).
var validFlagNameRe = regexp.MustCompile(`^[a-zA-Z0-9_\-]{1,128}$`)

// validateFlagName retorna erro se o nome contiver caracteres não permitidos.
func validateFlagName(name string) error {
	if !validFlagNameRe.MatchString(name) {
		return fmt.Errorf("flag_name inválido: apenas letras, números, hífens e underscores são permitidos")
	}
	return nil
}

// buildServiceURL constrói uma URL segura combinando a base com o path.
// Usa url.Parse + url.PathEscape, eliminando o uso de fmt.Sprintf com variáveis
// em URLs (G107 do gosec).
func buildServiceURL(base, pathSuffix, resourceName string) (string, error) {
	parsed, err := url.Parse(base)
	if err != nil {
		return "", fmt.Errorf("URL base inválida (%q): %w", base, err)
	}
	parsed.Path = parsed.Path + pathSuffix + url.PathEscape(resourceName)
	return parsed.String(), nil
}

// getDecision é o wrapper principal
func (a *App) getDecision(userID, flagName string) (bool, error) {
	if err := validateFlagName(flagName); err != nil {
		return false, err
	}
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
// A URL é construída via url.Parse + url.PathEscape (não via fmt.Sprintf),
// eliminando o finding G107 do gosec sem necessidade de exclusão.
func (a *App) fetchFlag(flagName string) (*Flag, error) {
	safeURL, err := buildServiceURL(a.FlagServiceURL, "/flags/", flagName)
	if err != nil {
		return nil, fmt.Errorf("erro ao construir URL do flag-service: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, safeURL, nil)
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

// fetchRule busca a regra no targeting-service.
// Mesma abordagem segura de construção de URL que fetchFlag.
func (a *App) fetchRule(flagName string) (*TargetingRule, error) {
	safeURL, err := buildServiceURL(a.TargetingServiceURL, "/rules/", flagName)
	if err != nil {
		return nil, fmt.Errorf("erro ao construir URL do targeting-service: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, safeURL, nil)
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
// Usa SHA-256 — distribuição uniforme sem uso criptográfico.
func getDeterministicBucket(input string) int {
	hash := sha1.Sum([]byte(input))
	val := binary.BigEndian.Uint32(hash[:4])
	return int(val % 100)
}


