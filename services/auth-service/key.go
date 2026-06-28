package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
)

// generateAPIKey cria uma string aleatória segura de 32 bytes
func generateAPIKey() (string, error) {
	bytes := make([]byte, 32)
	if _, err := rand.Read(bytes); err != nil {
		return "", err
	}
	return "tm_key_" + hex.EncodeToString(bytes), nil
}

func hashAPIKey(key string) string {
	hash := sha256.Sum256([]byte(key))
	return hex.EncodeToString(hash[:])
}
