package workload

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

const (
	APIVersion     = "perflab.io/v1"
	KindManifest   = "WorkloadManifest"
	ActiveRevision = "v1"
)

var CheckoutOperations = []string{"login", "browse", "create", "pay", "poll", "verify"}

type Manifest struct {
	APIVersion       string     `json:"apiVersion"`
	Kind             string     `json:"kind"`
	ContractRevision string     `json:"contractRevision"`
	Selectors        []Selector `json:"selectors"`
}

type Selector struct {
	ID                string            `json:"id"`
	Type              string            `json:"type"`
	IterationContract string            `json:"iterationContract"`
	Generators        []string          `json:"generators"`
	Entrypoints       map[string]string `json:"entrypoints,omitempty"`
	Files             []string          `json:"files,omitempty"`
	Operations        []string          `json:"operations,omitempty"`
	Targets           []string          `json:"targets,omitempty"`
	MemberKind        string            `json:"memberKind,omitempty"`
	Members           []Member          `json:"members,omitempty"`
	Amplification     *Amplification    `json:"amplification,omitempty"`
}

type Member struct {
	Selector string  `json:"selector"`
	Weight   float64 `json:"weight"`
}

type Amplification struct {
	Min float64 `json:"min,omitempty"`
	Max float64 `json:"max,omitempty"`
}

type PartitionState struct {
	RunID        string
	Seeded       bool
	ResetOK      bool
	Acknowledged bool
	Budget       int
}

func Parse(raw []byte) (Manifest, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	var manifest Manifest
	if err := dec.Decode(&manifest); err != nil {
		return Manifest{}, fmt.Errorf("strict workload parse: %w", err)
	}
	if err := Validate(manifest); err != nil {
		return Manifest{}, err
	}
	return manifest, nil
}

func LoadFile(path string) (Manifest, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return Manifest{}, err
	}
	return Parse(raw)
}

func Validate(manifest Manifest) error {
	if manifest.APIVersion != APIVersion {
		return fmt.Errorf("apiVersion must be %s", APIVersion)
	}
	if manifest.Kind != KindManifest {
		return fmt.Errorf("kind must be %s", KindManifest)
	}
	if manifest.ContractRevision != ActiveRevision {
		return fmt.Errorf("unknown contract revision %q rejected before target lease, mutation, deployment, or traffic", manifest.ContractRevision)
	}
	if len(manifest.Selectors) < 1 {
		return fmt.Errorf("selectors must contain at least one entry")
	}
	index := map[string]Selector{}
	for _, selector := range manifest.Selectors {
		if selector.ID == "" {
			return fmt.Errorf("selector id is required")
		}
		if _, dup := index[selector.ID]; dup {
			return fmt.Errorf("duplicate selector %q", selector.ID)
		}
		if err := validateSelector(selector); err != nil {
			return err
		}
		index[selector.ID] = selector
	}
	for _, selector := range manifest.Selectors {
		if selector.Type != "mix" {
			continue
		}
		if err := validateHomogeneousMix(selector, index); err != nil {
			return err
		}
	}
	return nil
}

func validateSelector(selector Selector) error {
	switch selector.Type {
	case "request", "journey", "mix", "protocol":
	default:
		return fmt.Errorf("selector %s: invalid type", selector.ID)
	}
	wantIter := map[string]string{
		"request": "one-request",
		"journey": "one-journey",
		"mix":     "one-selection",
	}
	if selector.Type != "protocol" && selector.IterationContract != wantIter[selector.Type] {
		return fmt.Errorf("selector %s: iterationContract %q does not match type %s", selector.ID, selector.IterationContract, selector.Type)
	}
	if len(selector.Generators) < 1 {
		return fmt.Errorf("selector %s: generators required", selector.ID)
	}
	if selector.Type == "mix" {
		if selector.MemberKind != "request" && selector.MemberKind != "journey" {
			return fmt.Errorf("selector %s: memberKind must be request XOR journey", selector.ID)
		}
		if len(selector.Members) < 1 {
			return fmt.Errorf("selector %s: mix members required", selector.ID)
		}
	}
	if selector.Type == "journey" && len(selector.Operations) > 0 {
		if err := ValidateCheckoutOperations(selector.Operations); err != nil {
			return fmt.Errorf("selector %s: %w", selector.ID, err)
		}
	}
	return nil
}

func validateHomogeneousMix(selector Selector, index map[string]Selector) error {
	total := 0.0
	for _, member := range selector.Members {
		if member.Weight <= 0 {
			return fmt.Errorf("selector %s: member weight must be finite and positive", selector.ID)
		}
		total += member.Weight
		resolved, ok := index[member.Selector]
		if !ok {
			return fmt.Errorf("selector %s: member %q is not in this manifest", selector.ID, member.Selector)
		}
		if resolved.Type == "mix" {
			return fmt.Errorf("selector %s: nested mixes are invalid", selector.ID)
		}
		if resolved.Type != selector.MemberKind {
			return fmt.Errorf("selector %s: heterogeneous mix members are unsupported (memberKind %s vs %s)", selector.ID, selector.MemberKind, resolved.Type)
		}
	}
	if total <= 0 {
		return fmt.Errorf("selector %s: mix weight total is not finite and positive", selector.ID)
	}
	return nil
}

func ValidateCheckoutOperations(ops []string) error {
	if len(ops) != len(CheckoutOperations) {
		return fmt.Errorf("checkout journey requires six operations %s", strings.Join(CheckoutOperations, ","))
	}
	for i, name := range CheckoutOperations {
		if ops[i] != name {
			return fmt.Errorf("checkout operation[%d] must be %s, got %s", i, name, ops[i])
		}
	}
	return nil
}

func RequirePartitionForWrites(op string, partition PartitionState) error {
	switch op {
	case "create", "pay":
		if !partition.Seeded || !partition.ResetOK || !partition.Acknowledged || partition.Budget <= 0 || partition.RunID == "" {
			return fmt.Errorf("journey operation %s requires managed-reference run-partition seed/reset, acknowledgement, budget, and unique runId before traffic", op)
		}
	}
	return nil
}

func Resolve(manifest Manifest, id string) (Selector, error) {
	for _, selector := range manifest.Selectors {
		if selector.ID == id {
			return selector, nil
		}
	}
	return Selector{}, fmt.Errorf("unknown selector %q", id)
}
