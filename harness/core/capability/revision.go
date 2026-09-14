package capability

import (
	"fmt"
)

func ParseRevisionNumber(revision string) (int, error) {
	if revision != "v1" {
		return 0, fmt.Errorf("unknown contract revision %q rejected before target lease, mutation, deployment, or traffic", revision)
	}
	return 1, nil
}

func RevisionAtLeast(revision string, min int) bool {
	n, err := ParseRevisionNumber(revision)
	return err == nil && n >= min
}

func RejectUnknownRevision(revision string) error {
	if revision == "" {
		revision = "v1"
	}
	_, err := ParseRevisionNumber(revision)
	return err
}
