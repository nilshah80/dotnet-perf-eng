package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"sort"
)

func hashFiles(root string, files []string) (string, error) {
	ordered := append([]string(nil), files...)
	sort.Strings(ordered)
	sum := sha256.New()
	for _, rel := range ordered {
		body, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
		if err != nil {
			return "", fmt.Errorf("read %s: %w", rel, err)
		}
		_, _ = sum.Write([]byte(rel))
		_, _ = sum.Write([]byte{'\n'})
		_, _ = sum.Write(body)
		_, _ = sum.Write([]byte{0})
	}
	return hex.EncodeToString(sum.Sum(nil)), nil
}

func hashBytes(body []byte) string {
	sum := sha256.Sum256(body)
	return hex.EncodeToString(sum[:])
}
