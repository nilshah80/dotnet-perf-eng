package workload

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestHeterogeneousMixFixtureRejected(t *testing.T) {
	root := findRoot(t)
	raw, err := os.ReadFile(filepath.Join(root, "contracts/v1/fixtures/catalog/heterogeneous-mix-invalid.json"))
	if err != nil {
		t.Fatal(err)
	}
	_, err = Parse(raw)
	if err == nil {
		t.Fatal("expected heterogeneous mix rejection")
	}
	if !strings.Contains(err.Error(), "member") && !strings.Contains(err.Error(), "not in this manifest") {
		t.Fatal(err)
	}
}

func TestHomogeneousRequestMixAccepted(t *testing.T) {
	raw := []byte(`{
  "apiVersion": "perflab.io/v1",
  "kind": "WorkloadManifest",
  "contractRevision": "v1",
  "selectors": [
    {"id": "E00", "type": "request", "iterationContract": "one-request", "generators": ["k6"]},
    {"id": "E05", "type": "request", "iterationContract": "one-request", "generators": ["k6"]},
    {
      "id": "browse-mix",
      "type": "mix",
      "iterationContract": "one-selection",
      "generators": ["k6"],
      "memberKind": "request",
      "members": [
        {"selector": "E00", "weight": 70},
        {"selector": "E05", "weight": 30}
      ]
    }
  ]
}
`)
	manifest, err := Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	sel, err := Resolve(manifest, "browse-mix")
	if err != nil {
		t.Fatal(err)
	}
	if sel.MemberKind != "request" {
		t.Fatal(sel)
	}
}

func TestCheckoutDescriptor(t *testing.T) {
	if err := ValidateCheckoutOperations(CheckoutOperations); err != nil {
		t.Fatal(err)
	}
	if err := ValidateCheckoutOperations([]string{"login", "browse"}); err == nil {
		t.Fatal("short list must fail")
	}
	raw := []byte(`{
  "apiVersion": "perflab.io/v1",
  "kind": "WorkloadManifest",
  "contractRevision": "v1",
  "selectors": [
    {
      "id": "checkout",
      "type": "journey",
      "iterationContract": "one-journey",
      "generators": ["k6", "jmeter"],
      "operations": ["login", "browse", "create", "pay", "poll", "verify"],
      "amplification": {"min": 6, "max": 12}
    }
  ]
}
`)
	if _, err := Parse(raw); err != nil {
		t.Fatal(err)
	}
}

func TestEcommerceManifestAndCheckout(t *testing.T) {
	root := findRoot(t)
	manifest, err := LoadFile(filepath.Join(root, "labs/ecommerce/workload-manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	sel, err := Resolve(manifest, "checkout")
	if err != nil {
		t.Fatal(err)
	}
	if sel.Type != "journey" {
		t.Fatal(sel)
	}
}

func TestCreatePayRequirePartition(t *testing.T) {
	empty := PartitionState{}
	if err := RequirePartitionForWrites("login", empty); err != nil {
		t.Fatal(err)
	}
	if err := RequirePartitionForWrites("create", empty); err == nil {
		t.Fatal("create must require partition")
	}
	if err := RequirePartitionForWrites("pay", empty); err == nil {
		t.Fatal("pay must require partition")
	}
	ready := PartitionState{RunID: "run-1", Seeded: true, ResetOK: true, Acknowledged: true, Budget: 100}
	if err := RequirePartitionForWrites("create", ready); err != nil {
		t.Fatal(err)
	}
}

func findRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 8; i++ {
		if _, err := os.Stat(filepath.Join(dir, "contracts", "contract-manifest.json")); err == nil {
			return dir
		}
		dir = filepath.Dir(dir)
	}
	t.Fatal("repo root not found")
	return ""
}
