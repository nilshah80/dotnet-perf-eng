package catalog

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

const (
	APIVersion      = "perflab.io/v1"
	KindCatalog     = "ScenarioCatalog"
	ActiveRevision  = "v1"
	revisionPattern = `^v1$`
	tokenPattern    = `^[A-Za-z0-9._-]{1,128}$`
)

var (
	reRevision = regexp.MustCompile(revisionPattern)
	reToken    = regexp.MustCompile(tokenPattern)
)

// ScenarioCatalog is the v1 catalog document. Unknown JSON fields fail
// closed in strict mode.
type ScenarioCatalog struct {
	APIVersion       string     `json:"apiVersion"`
	Kind             string     `json:"kind"`
	ContractRevision string     `json:"contractRevision"`
	Scenarios        []Scenario `json:"scenarios"`
}

type Scenario struct {
	ID          string       `json:"id"`
	Name        string       `json:"name"`
	Workload    WorkloadRef  `json:"workload"`
	Targets     []string     `json:"targets,omitempty"`
	Effects     *Effects     `json:"effects,omitempty"`
	Services    *Services    `json:"services,omitempty"`
	Defaults    *Defaults    `json:"defaults,omitempty"`
	Lifecycle   *Lifecycle   `json:"lifecycle,omitempty"`
	WriteSafety *WriteSafety `json:"writeSafety,omitempty"`
	Diagnostics *Diagnostics `json:"diagnostics,omitempty"`
	SLOProfile  string       `json:"sloProfile,omitempty"`
}

type WorkloadRef struct {
	Type     string `json:"type"`
	Selector string `json:"selector"`
}

type Effects struct {
	Classification string `json:"classification,omitempty"`
	Replayable     bool   `json:"replayable,omitempty"`
	ResetPolicy    string `json:"resetPolicy,omitempty"`
}

type Services struct {
	Required      []string `json:"required,omitempty"`
	Participating []string `json:"participating,omitempty"`
}

type Defaults struct {
	LoadModel string  `json:"loadModel,omitempty"`
	Rate      float64 `json:"rate,omitempty"`
	RateUnit  string  `json:"rateUnit,omitempty"`
}

// Lifecycle owns start/stop/deploy rights. It must never share an enum with
// WriteSafety.
type Lifecycle struct {
	Ownership string `json:"ownership,omitempty"`
}

// WriteSafety records whether mutating work is allowed. Distinct from Lifecycle.
type WriteSafety struct {
	Class string `json:"class,omitempty"`
}

type Diagnostics struct {
	Targets         []string `json:"targets,omitempty"`
	Preset          string   `json:"preset,omitempty"`
	SourceLoadLevel string   `json:"sourceLoadLevel,omitempty"`
}

func UnknownRevisionError(revision string) error {
	return fmt.Errorf("unknown contract revision %q rejected before target lease, mutation, deployment, or traffic", revision)
}

func LoadFile(path string) (ScenarioCatalog, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return ScenarioCatalog{}, err
	}
	return Parse(raw)
}

func Parse(raw []byte) (ScenarioCatalog, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	var catalog ScenarioCatalog
	if err := dec.Decode(&catalog); err != nil {
		return ScenarioCatalog{}, fmt.Errorf("strict catalog parse: %w", err)
	}
	if dec.More() {
		return ScenarioCatalog{}, fmt.Errorf("trailing JSON document")
	}
	if err := Validate(catalog); err != nil {
		return ScenarioCatalog{}, err
	}
	return catalog, nil
}

func Validate(catalog ScenarioCatalog) error {
	if catalog.APIVersion != APIVersion {
		return fmt.Errorf("apiVersion must be %s", APIVersion)
	}
	if catalog.Kind != KindCatalog {
		return fmt.Errorf("kind must be %s", KindCatalog)
	}
	if !reRevision.MatchString(catalog.ContractRevision) || catalog.ContractRevision != ActiveRevision {
		return UnknownRevisionError(catalog.ContractRevision)
	}
	if len(catalog.Scenarios) < 1 {
		return fmt.Errorf("scenarios must contain at least one entry")
	}
	seen := map[string]struct{}{}
	for i, scenario := range catalog.Scenarios {
		if err := validateScenario(i, scenario, seen); err != nil {
			return err
		}
	}
	return nil
}

func validateScenario(index int, scenario Scenario, seen map[string]struct{}) error {
	if !reToken.MatchString(scenario.ID) {
		return fmt.Errorf("scenario[%d]: id is not a stable token", index)
	}
	if strings.TrimSpace(scenario.Name) == "" || len(scenario.Name) > 128 {
		return fmt.Errorf("scenario %s: name is required and at most 128 characters", scenario.ID)
	}
	if _, dup := seen[scenario.ID]; dup {
		return fmt.Errorf("duplicate scenario id %q", scenario.ID)
	}
	seen[scenario.ID] = struct{}{}
	switch scenario.Workload.Type {
	case "request", "journey", "mix", "protocol":
	default:
		return fmt.Errorf("scenario %s: workload.type is invalid", scenario.ID)
	}
	if !reToken.MatchString(scenario.Workload.Selector) {
		return fmt.Errorf("scenario %s: workload.selector is not a stable token", scenario.ID)
	}
	if err := validateRate(scenario); err != nil {
		return err
	}
	if scenario.Lifecycle != nil {
		switch scenario.Lifecycle.Ownership {
		case "", "none", "managed", "delegated":
		default:
			return fmt.Errorf("scenario %s: lifecycle.ownership is invalid", scenario.ID)
		}
	}
	if scenario.WriteSafety != nil {
		switch scenario.WriteSafety.Class {
		case "", "none", "managed-reference":
		default:
			return fmt.Errorf("scenario %s: writeSafety.class is invalid", scenario.ID)
		}
	}
	if scenario.Effects != nil {
		switch scenario.Effects.Classification {
		case "", "read", "idempotent-write", "write", "destructive":
		default:
			return fmt.Errorf("scenario %s: effects.classification is invalid", scenario.ID)
		}
	}
	return nil
}

func validateRate(scenario Scenario) error {
	if scenario.Defaults == nil {
		return nil
	}
	unit := scenario.Defaults.RateUnit
	model := scenario.Defaults.LoadModel
	if model != "" && model != "open" && model != "closed" {
		return fmt.Errorf("scenario %s: defaults.loadModel is invalid", scenario.ID)
	}
	if unit == "" {
		return nil
	}
	ok := false
	switch scenario.Workload.Type {
	case "request":
		if model == "closed" {
			ok = unit == "concurrent-iterations"
		} else {
			ok = unit == "requests/s" || unit == "iterations/s"
		}
	case "journey":
		if model == "closed" {
			ok = unit == "concurrent-users"
		} else {
			ok = unit == "journeys/s" || unit == "iterations/s"
		}
	case "mix":
		if model == "closed" {
			ok = unit == "concurrent-iterations" || unit == "concurrent-users"
		} else {
			ok = unit == "selections/s" || unit == "journeys/s" || unit == "iterations/s" || unit == "requests/s"
		}
	case "protocol":
		ok = true
	}
	if !ok {
		return fmt.Errorf("scenario %s: rateUnit %q is incompatible with workload %s and loadModel %q", scenario.ID, unit, scenario.Workload.Type, model)
	}
	return nil
}

func Encode(catalog ScenarioCatalog) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(catalog); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func Find(catalog ScenarioCatalog, id string) (Scenario, bool) {
	for _, scenario := range catalog.Scenarios {
		if scenario.ID == id {
			return scenario, true
		}
	}
	return Scenario{}, false
}

func RepoRootFrom(start string) (string, error) {
	dir, err := filepath.Abs(start)
	if err != nil {
		return "", err
	}
	for i := 0; i < 8; i++ {
		if _, err := os.Stat(filepath.Join(dir, "contracts", "contract-manifest.json")); err == nil {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return "", fmt.Errorf("native repo root not found from %s", start)
}

func FixturePath(root, rel string) string {
	return filepath.Join(root, filepath.FromSlash(rel))
}
