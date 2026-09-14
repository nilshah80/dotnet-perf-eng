package main

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"strings"
)

//go:embed adapter-manifest.json
var bundledManifest []byte

var hex64 = regexp.MustCompile(`^[a-f0-9]{64}$`)

// Manifest is the native adapter identity shipped beside the runner.
type Manifest struct {
	AdapterID          string  `json:"adapterId"`
	AdapterVersion     string  `json:"adapterVersion"`
	Generator          string  `json:"generator"`
	CPUs               float64 `json:"cpus"`
	MemoryBytes        int64   `json:"memoryBytes"`
	MaxThreads         int     `json:"maxThreads"`
	CapabilityRevision string  `json:"capabilityRevision"`
	ContractDigest     string  `json:"contractDigest"`
}

// VersionDocument is the jmeter-adapter-wire payload for `version --json`.
type VersionDocument struct {
	Generator          string   `json:"generator"`
	AdapterID          string   `json:"adapterId"`
	AdapterVersion     string   `json:"adapterVersion"`
	ImageDigest        string   `json:"imageDigest"`
	CPUs               float64  `json:"cpus"`
	MemoryBytes        int64    `json:"memoryBytes"`
	MaxThreads         int      `json:"maxThreads"`
	Modes              []string `json:"modes"`
	Fingerprint        string   `json:"fingerprint"`
	CapabilityRevision string   `json:"capabilityRevision"`
	ContractDigest     string   `json:"contractDigest"`
}

func loadManifest() (Manifest, error) {
	raw := bundledManifest
	if path := strings.TrimSpace(os.Getenv("ADAPTER_MANIFEST")); path != "" {
		body, err := os.ReadFile(path)
		if err != nil {
			return Manifest{}, fmt.Errorf("read adapter manifest: %w", err)
		}
		raw = body
	}
	var m Manifest
	if err := json.Unmarshal(raw, &m); err != nil {
		return Manifest{}, fmt.Errorf("decode adapter manifest: %w", err)
	}
	if err := m.validate(); err != nil {
		return Manifest{}, err
	}
	return m, nil
}

func (m Manifest) validate() error {
	if strings.TrimSpace(m.AdapterID) == "" {
		return fmt.Errorf("adapter manifest omitted adapterId")
	}
	if strings.TrimSpace(m.AdapterVersion) == "" {
		return fmt.Errorf("adapter manifest omitted adapterVersion")
	}
	if m.Generator != "" && m.Generator != "jmeter" {
		return fmt.Errorf("adapter manifest generator %q is not jmeter", m.Generator)
	}
	if m.CPUs <= 0 {
		return fmt.Errorf("adapter manifest cpus must be positive")
	}
	if m.MemoryBytes <= 0 {
		return fmt.Errorf("adapter manifest memoryBytes must be positive")
	}
	if m.MaxThreads <= 0 {
		return fmt.Errorf("adapter manifest maxThreads must be positive")
	}
	return nil
}

func currentVersion(m Manifest) VersionDocument {
	digest := strings.TrimSpace(os.Getenv("PERFLAB_PLUGIN_IMAGE_DIGEST"))
	revision := strings.TrimSpace(m.CapabilityRevision)
	if revision == "" {
		revision = "v1"
	}
	contract := strings.TrimSpace(os.Getenv("PERFLAB_CONTRACT_DIGEST"))
	if contract == "" {
		contract = strings.TrimSpace(m.ContractDigest)
	}
	doc := VersionDocument{
		Generator:          "jmeter",
		AdapterID:          m.AdapterID,
		AdapterVersion:     m.AdapterVersion,
		ImageDigest:        digest,
		CPUs:               m.CPUs,
		MemoryBytes:        m.MemoryBytes,
		MaxThreads:         m.MaxThreads,
		Modes:              []string{"run-once", "normalize", "version"},
		CapabilityRevision: revision,
		ContractDigest:     contract,
	}
	doc.Fingerprint = versionFingerprint(doc)
	return doc
}

func versionFingerprint(doc VersionDocument) string {
	return strings.Join([]string{
		"adapter=" + doc.AdapterVersion,
		"maxThreads=" + fmt.Sprintf("%d", doc.MaxThreads),
		"id=" + doc.AdapterID,
	}, ";")
}

func cmdVersion(args []string) int {
	jsonOut := false
	for _, arg := range args {
		switch arg {
		case "--json":
			jsonOut = true
		default:
			fmt.Fprintf(os.Stderr, "unknown version flag %q\n", arg)
			return exitUsage
		}
	}
	m, err := loadManifest()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return exitPublish
	}
	doc := currentVersion(m)
	if !jsonOut {
		fmt.Fprintf(os.Stdout, "%s %s generator=jmeter maxThreads=%d\n", doc.AdapterID, doc.AdapterVersion, doc.MaxThreads)
		return exitOK
	}
	if err := ValidateVersionDocument(doc); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return exitPublish
	}
	raw, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return exitPublish
	}
	fmt.Fprintln(os.Stdout, string(raw))
	return exitOK
}

// ValidateVersionDocument rejects wire payloads that cannot satisfy the
// jmeter-adapter-wire schema conceptually (empty identity, non-positive
// ceilings, wrong generator, missing modes).
func ValidateVersionDocument(doc VersionDocument) error {
	if doc.Generator != "jmeter" {
		return fmt.Errorf("version generator must be jmeter")
	}
	if strings.TrimSpace(doc.AdapterID) == "" {
		return fmt.Errorf("version adapterId is empty")
	}
	if strings.TrimSpace(doc.AdapterVersion) == "" {
		return fmt.Errorf("version adapterVersion is empty")
	}
	if doc.CPUs <= 0 {
		return fmt.Errorf("version cpus must be positive")
	}
	if doc.MemoryBytes <= 0 {
		return fmt.Errorf("version memoryBytes must be positive")
	}
	if doc.MaxThreads <= 0 {
		return fmt.Errorf("version maxThreads must be positive")
	}
	if strings.TrimSpace(doc.Fingerprint) == "" {
		return fmt.Errorf("version fingerprint is empty")
	}
	if !strings.HasPrefix(doc.Fingerprint, "adapter=") {
		return fmt.Errorf("version fingerprint must start with adapter=")
	}
	want := map[string]bool{"run-once": false, "normalize": false, "version": false}
	for _, mode := range doc.Modes {
		if _, ok := want[mode]; !ok {
			return fmt.Errorf("version modes contains unknown %q", mode)
		}
		want[mode] = true
	}
	for mode, seen := range want {
		if !seen {
			return fmt.Errorf("version modes omitted %s", mode)
		}
	}
	if doc.ContractDigest != "" && !hex64.MatchString(doc.ContractDigest) {
		return fmt.Errorf("version contractDigest is not a sha256 hex digest")
	}
	return nil
}

func decodeAndValidateVersionJSON(raw []byte) (VersionDocument, error) {
	var doc VersionDocument
	if err := json.Unmarshal(raw, &doc); err != nil {
		return VersionDocument{}, fmt.Errorf("malformed version json: %w", err)
	}
	if err := ValidateVersionDocument(doc); err != nil {
		return VersionDocument{}, err
	}
	return doc, nil
}
