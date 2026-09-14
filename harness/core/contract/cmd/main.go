package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"
)

const reservedManifest = "meta/contract-manifest.json"

type entry struct {
	LogicalName string `json:"logicalName"`
	Kind        string `json:"kind"`
	MediaType   string `json:"mediaType"`
	ContentMode string `json:"contentMode"`
}

type manifest struct {
	ContractRevision string  `json:"contractRevision"`
	Entries          []entry `json:"entries"`
}

type mapped struct {
	LogicalName string `json:"logicalName"`
	Path        string `json:"path"`
}

type pathMap struct {
	Manifest string   `json:"manifest"`
	Paths    []mapped `json:"paths"`
}

type lockEntry struct {
	LogicalName string `json:"logicalName"`
	SHA256      string `json:"sha256"`
}

type lockFile struct {
	ContractRevision string      `json:"contractRevision"`
	ManifestSHA256   string      `json:"manifestSha256"`
	HashAlgorithm    string      `json:"hashAlgorithm"`
	Entries          []lockEntry `json:"entries"`
	AggregateSHA256  string      `json:"aggregateSha256"`
}

type indexRevision struct {
	Revision        string `json:"revision"`
	ManifestSHA256  string `json:"manifestSha256"`
	AggregateSHA256 string `json:"aggregateSha256"`
}

type indexFile struct {
	ActiveRevision string          `json:"activeRevision"`
	Revisions      []indexRevision `json:"revisions"`
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "Usage: native-contract check|generate-lock|attest [root]")
		os.Exit(2)
	}
	root := "."
	if len(os.Args) > 2 {
		root = os.Args[2]
	}
	abs, err := filepath.Abs(root)
	if err != nil {
		die(err)
	}
	switch os.Args[1] {
	case "generate-lock":
		die(writeLock(abs))
	case "check":
		die(verifyLock(abs))
	case "attest":
		die(writeAttestation(abs))
	default:
		die(fmt.Errorf("unknown command %s", os.Args[1]))
	}
}

func writeLock(root string) error {
	lock, err := compute(root)
	if err != nil {
		return err
	}
	raw, err := encode(lock)
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(root, "contracts/contract-lock.json"), raw, 0o644); err != nil {
		return err
	}
	history := filepath.Join(root, "contracts/contract-history/v1")
	if err := os.MkdirAll(history, 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(history, "contract-lock.json"), raw, 0o644); err != nil {
		return err
	}
	manifest, err := os.ReadFile(filepath.Join(root, "contracts/contract-manifest.json"))
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(history, "contract-manifest.json"), manifest, 0o644); err != nil {
		return err
	}
	index := indexFile{ActiveRevision: "v1", Revisions: []indexRevision{{
		Revision: "v1", ManifestSHA256: lock.ManifestSHA256, AggregateSHA256: lock.AggregateSHA256,
	}}}
	indexRaw, err := encode(index)
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(root, "contracts/contract-index.json"), indexRaw, 0o644)
}

func verifyLock(root string) error {
	lock, err := compute(root)
	if err != nil {
		return err
	}
	raw, err := encode(lock)
	if err != nil {
		return err
	}
	got, err := os.ReadFile(filepath.Join(root, "contracts/contract-lock.json"))
	if err != nil {
		return err
	}
	if string(got) != string(raw) {
		return fmt.Errorf("contracts/contract-lock.json is dirty")
	}
	indexRaw, err := os.ReadFile(filepath.Join(root, "contracts/contract-index.json"))
	if err != nil {
		return err
	}
	var index struct {
		ActiveRevision string `json:"activeRevision"`
		Revisions      []struct {
			Revision        string `json:"revision"`
			ManifestSHA256  string `json:"manifestSha256"`
			AggregateSHA256 string `json:"aggregateSha256"`
		} `json:"revisions"`
	}
	if err := json.Unmarshal(indexRaw, &index); err != nil {
		return err
	}
	if index.ActiveRevision != "v1" {
		return fmt.Errorf("unknown contract revision %q rejected before target lease, mutation, deployment, or traffic", index.ActiveRevision)
	}
	if len(index.Revisions) != 1 {
		return fmt.Errorf("contract-index.json must contain only the released stable v1 revision")
	}
	foundFrozen := false
	for _, item := range index.Revisions {
		if item.Revision == "v1" {
			foundFrozen = true
			if item.AggregateSHA256 != lock.AggregateSHA256 || item.ManifestSHA256 != lock.ManifestSHA256 {
				return fmt.Errorf("contract-index.json v1 digest does not match the frozen lock")
			}
			continue
		}
		rel := filepath.ToSlash(filepath.Join("contracts/contract-history", item.Revision, "contract-path-map.json"))
		gotLock, err := computeAt(root, rel, item.Revision)
		if err != nil {
			return fmt.Errorf("%s: %w", item.Revision, err)
		}
		hist, err := os.ReadFile(filepath.Join(root, "contracts/contract-history", item.Revision, "contract-lock.json"))
		if err != nil {
			return err
		}
		encoded, err := encode(gotLock)
		if err != nil {
			return err
		}
		if string(hist) != string(encoded) {
			return fmt.Errorf("%s history lock is dirty", item.Revision)
		}
		if gotLock.AggregateSHA256 != item.AggregateSHA256 || gotLock.ManifestSHA256 != item.ManifestSHA256 {
			return fmt.Errorf("%s index digest does not match history lock", item.Revision)
		}
	}
	if !foundFrozen {
		return fmt.Errorf("contract-index.json is missing the frozen v1 entry")
	}
	fmt.Printf("v1 lock ok aggregate=%s revisions=%d\n", lock.AggregateSHA256, len(index.Revisions))
	return nil
}

func writeAttestation(root string) error {
	lock, err := compute(root)
	if err != nil {
		return err
	}
	parityRaw, err := os.ReadFile(filepath.Join(root, "parity-lock.json"))
	if err != nil {
		return err
	}
	if err := textOK(parityRaw); err != nil {
		return err
	}
	var parity map[string]string
	if err := json.Unmarshal(parityRaw, &parity); err != nil {
		return err
	}
	plan, err := os.ReadFile(filepath.Join(root, "docs/REAL-WORLD-PERFORMANCE-ENGINEERING-IMPLEMENTATION-PLAN.md"))
	if err != nil {
		return err
	}
	planHash := sha(plan)
	if planHash != parity["planSha256"] {
		return fmt.Errorf("plan digest mismatch")
	}
	if parity["contractRevision"] != lock.ContractRevision || parity["manifestSha256"] != lock.ManifestSHA256 || parity["aggregateSha256"] != lock.AggregateSHA256 {
		return fmt.Errorf("parity-lock does not match native contract lock")
	}
	indexRaw, err := os.ReadFile(filepath.Join(root, "contracts/contract-index.json"))
	if err != nil {
		return err
	}
	if sha(indexRaw) != parity["contractIndexSha256"] {
		return fmt.Errorf("contract-index digest mismatch")
	}
	inv, err := os.ReadFile(filepath.Join(root, "harness/inventories/compatibility-inventory.json"))
	if err != nil {
		return err
	}
	if sha(inv) != parity["dotnetPerfEngInventorySha256"] {
		return fmt.Errorf("native inventory digest mismatch")
	}
	att := map[string]string{
		"repository":                   "dotnet-perf-eng",
		"contractRevision":             lock.ContractRevision,
		"planSha256":                   planHash,
		"manifestSha256":               lock.ManifestSHA256,
		"aggregateSha256":              lock.AggregateSHA256,
		"contractIndexSha256":          sha(indexRaw),
		"inventorySha256":              sha(inv),
		"inventoryField":               "dotnetPerfEngInventorySha256",
		"perflabInventorySha256":       parity["perflabInventorySha256"],
		"dotnetPerfEngInventorySha256": parity["dotnetPerfEngInventorySha256"],
	}
	raw, err := encode(att)
	if err != nil {
		return err
	}
	dir := filepath.Join(root, "artifacts/parity")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, "parity-attestation.json"), raw, 0o644); err != nil {
		return err
	}
	fmt.Printf("wrote %s\n", filepath.Join(dir, "parity-attestation.json"))
	return nil
}

func compute(root string) (lockFile, error) {
	return computeAt(root, "contracts/contract-path-map.json", "v1")
}

func computeAt(root, pathMapRel, revision string) (lockFile, error) {
	pmRaw, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(pathMapRel)))
	if err != nil {
		return lockFile{}, err
	}
	var pm pathMap
	if err := json.Unmarshal(pmRaw, &pm); err != nil {
		return lockFile{}, err
	}
	mfRaw, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(pm.Manifest)))
	if err != nil {
		return lockFile{}, err
	}
	if err := textOK(mfRaw); err != nil {
		return lockFile{}, fmt.Errorf("manifest: %w", err)
	}
	var mf manifest
	if err := json.Unmarshal(mfRaw, &mf); err != nil {
		return lockFile{}, err
	}
	files := map[string]string{reservedManifest: pm.Manifest}
	for _, item := range pm.Paths {
		files[item.LogicalName] = item.Path
	}
	if mf.ContractRevision != revision {
		return lockFile{}, fmt.Errorf("unknown contract revision %q rejected before target lease, mutation, deployment, or traffic", mf.ContractRevision)
	}
	declared := map[string]entry{}
	for _, item := range mf.Entries {
		declared[item.LogicalName] = item
	}
	names := make([]string, 0, len(files))
	for name := range files {
		names = append(names, name)
	}
	sort.Slice(names, func(i, j int) bool { return names[i] < names[j] })
	lock := lockFile{ContractRevision: revision, ManifestSHA256: sha(mfRaw), HashAlgorithm: "sha256"}
	var pre []byte
	for _, name := range names {
		body, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(files[name])))
		if err != nil {
			return lockFile{}, err
		}
		if name == reservedManifest || declared[name].ContentMode != "binary" {
			if err := textOK(body); err != nil {
				return lockFile{}, fmt.Errorf("%s: %w", name, err)
			}
		}
		digest := sha(body)
		lock.Entries = append(lock.Entries, lockEntry{LogicalName: name, SHA256: digest})
		pre = append(pre, []byte(name)...)
		pre = append(pre, 0)
		pre = append(pre, []byte(digest)...)
		pre = append(pre, '\n')
	}
	lock.AggregateSHA256 = sha(pre)
	return lock, nil
}

func encode(v any) ([]byte, error) {
	raw, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return nil, err
	}
	return append(raw, '\n'), nil
}

func sha(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func textOK(b []byte) error {
	if len(b) >= 3 && b[0] == 0xef && b[1] == 0xbb && b[2] == 0xbf {
		return fmt.Errorf("BOM")
	}
	if !utf8.Valid(b) {
		return fmt.Errorf("utf-8")
	}
	if strings.Contains(string(b), "\r") {
		return fmt.Errorf("CR")
	}
	if len(b) == 0 || b[len(b)-1] != '\n' || (len(b) > 1 && b[len(b)-2] == '\n') {
		return fmt.Errorf("exactly one trailing LF required")
	}
	return nil
}

func die(err error) {
	if err == nil {
		return
	}
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
