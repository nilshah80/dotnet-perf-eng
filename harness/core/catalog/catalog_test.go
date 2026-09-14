package catalog

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRequestFixtureValidates(t *testing.T) {
	root := findRoot(t)
	catalog, err := LoadFile(filepath.Join(root, "contracts/v1/fixtures/catalog/request-valid.json"))
	if err != nil {
		t.Fatal(err)
	}
	got := catalog.Scenarios[0]
	if got.Workload.Type != "request" {
		t.Fatalf("type: %s", got.Workload.Type)
	}
	if got.Lifecycle == nil || got.WriteSafety == nil {
		t.Fatal("lifecycle.ownership and writeSafety.class must both be present")
	}
	if got.Lifecycle.Ownership == got.WriteSafety.Class && got.WriteSafety.Class != "none" {
		t.Fatal("ownership and write-safety collapsed into one value")
	}
}

func TestJourneyDescriptorValidatesWithoutAdvertisingSupport(t *testing.T) {
	root := findRoot(t)
	catalog, err := LoadFile(filepath.Join(root, "contracts/v1/fixtures/catalog/journey-descriptor-valid.json"))
	if err != nil {
		t.Fatal(err)
	}
	if catalog.Scenarios[0].Workload.Type != "journey" {
		t.Fatal(catalog.Scenarios[0].Workload)
	}
	if catalog.Scenarios[0].WriteSafety == nil || catalog.Scenarios[0].WriteSafety.Class != "managed-reference" {
		t.Fatal("journey descriptor must keep writeSafety.class separate")
	}
}

func TestTrailingJSONFailsClosed(t *testing.T) {
	_, err := Parse([]byte(`{"apiVersion":"perflab.io/v1","kind":"ScenarioCatalog","contractRevision":"v1","scenarios":[{"id":"a","name":"a","workload":{"type":"request","selector":"a"}}]}{"extra":true}` + "\n"))
	if err == nil {
		t.Fatal("expected trailing JSON rejection")
	}
}

func TestUnknownFieldFailsClosed(t *testing.T) {
	root := findRoot(t)
	_, err := LoadFile(filepath.Join(root, "contracts/v1/fixtures/catalog/unknown-field-strict.json"))
	if err == nil {
		t.Fatal("expected unknown field rejection")
	}
}

func TestUnknownRevisionFailsClosed(t *testing.T) {
	root := findRoot(t)
	raw, err := os.ReadFile(filepath.Join(root, "contracts/v1/fixtures/revision/unknown-revision.json"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), `"v2"`) {
		t.Fatal(string(raw))
	}
	_, err = Parse([]byte(`{"apiVersion":"perflab.io/v1","kind":"ScenarioCatalog","contractRevision":"v2","scenarios":[{"id":"a","name":"a","workload":{"type":"request","selector":"a"}}]}` + "\n"))
	if err == nil {
		t.Fatal("expected unknown revision rejection")
	}
	if !strings.Contains(err.Error(), "rejected before target lease") {
		t.Fatal(err)
	}
}

func TestTSVAdapterIsRequestOnly(t *testing.T) {
	rows := []TSVRow{
		{ID: "E00", Name: "control-products", Method: "GET", Path: "/api/products", Target: "api", Diagnostic: "trace", Connections: 64},
		{ID: "E07", Name: "product-create", Method: "POST", Path: "/api/products", Body: "{}", Target: "api", Connections: 32},
	}
	catalog := FromTSV(rows)
	if err := Validate(catalog); err != nil {
		t.Fatal(err)
	}
	if catalog.Scenarios[0].Workload.Type != "request" || catalog.Scenarios[1].Workload.Type != "request" {
		t.Fatal(catalog.Scenarios)
	}
	if catalog.Scenarios[0].Lifecycle.Ownership == "" || catalog.Scenarios[0].WriteSafety.Class == "" {
		t.Fatal("migrated rows must set both separate fields")
	}
	if catalog.Scenarios[1].Effects.Classification != "write" {
		t.Fatal(catalog.Scenarios[1].Effects)
	}
	if catalog.Scenarios[0].Defaults.RateUnit != "concurrent-iterations" {
		t.Fatal(catalog.Scenarios[0].Defaults)
	}
}

func TestLegacyIterationFixture(t *testing.T) {
	root := findRoot(t)
	if err := LoadIterationFixture(filepath.Join(root, "contracts/v1/fixtures/legacy-request-iteration-accounting.json")); err != nil {
		t.Fatal(err)
	}
}

func TestLabCatalogsValidate(t *testing.T) {
	root := findRoot(t)
	for _, rel := range []string{
		"labs/ecommerce/catalog.json",
		"labs/scenariolab/catalog.json",
		"labs/remote-example/catalog.json",
	} {
		doc, err := LoadFile(filepath.Join(root, rel))
		if err != nil {
			t.Fatalf("%s: %v", rel, err)
		}
		if doc.ContractRevision != ActiveRevision {
			t.Fatal(rel)
		}
	}
	ecom, err := LoadFile(filepath.Join(root, "labs/ecommerce/catalog.json"))
	if err != nil {
		t.Fatal(err)
	}
	checkout, ok := Find(ecom, "checkout")
	if !ok || checkout.Workload.Type != "journey" {
		t.Fatal("ecommerce catalog must include checkout journey")
	}
	if checkout.WriteSafety == nil || checkout.WriteSafety.Class != "managed-reference" {
		t.Fatal(checkout.WriteSafety)
	}
}

func TestEcommerceTSVMigrates(t *testing.T) {
	root := findRoot(t)
	rows, err := LoadTSV(filepath.Join(root, "labs/ecommerce/scenarios.tsv"))
	if err != nil {
		t.Fatal(err)
	}
	catalog := FromTSV(rows)
	if err := Validate(catalog); err != nil {
		t.Fatal(err)
	}
	if len(catalog.Scenarios) != 15 {
		t.Fatalf("got %d scenarios", len(catalog.Scenarios))
	}
}

func findRoot(t *testing.T) string {
	t.Helper()
	dir, _ := os.Getwd()
	root, err := RepoRootFrom(dir)
	if err != nil {
		t.Fatal(err)
	}
	return root
}
