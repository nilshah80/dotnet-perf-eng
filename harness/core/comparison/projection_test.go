package comparison

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestEligibleFrozenFixture(t *testing.T) {
	root := findRoot(t)
	raw, err := os.ReadFile(filepath.Join(root, "contracts/v1/fixtures/comparison/legacy-request-v1-eligible.json"))
	if err != nil {
		t.Fatal(err)
	}
	want, err := Decode(raw)
	if err != nil {
		t.Fatal(err)
	}
	got := ProjectLegacyRequestV1(EligibilityInput{
		WorkloadType:       "request",
		SourceDigest:       want.SourceCandidateDigest,
		ProjectedDigest:    want.ProjectedDigest,
		BaselineApprovalID: want.BaselineApprovalID,
	})
	assertProjection(t, got, want)
	if err := Inconclusive(got); err != nil {
		t.Fatal(err)
	}
}

func TestIneligibleJourneyFrozenFixture(t *testing.T) {
	root := findRoot(t)
	raw, err := os.ReadFile(filepath.Join(root, "contracts/v1/fixtures/comparison/legacy-request-v1-ineligible-journey.json"))
	if err != nil {
		t.Fatal(err)
	}
	want, err := Decode(raw)
	if err != nil {
		t.Fatal(err)
	}
	got := ProjectLegacyRequestV1(EligibilityInput{
		WorkloadType: "journey",
		HasJourney:   true,
		SourceDigest: want.SourceCandidateDigest,
	})
	assertProjection(t, got, want)
	if err := Inconclusive(got); err == nil {
		t.Fatal("journey comparison must be inconclusive")
	}
}

func TestLossyDimensionsAreInconclusive(t *testing.T) {
	for _, in := range []EligibilityInput{
		{WorkloadType: "mix", HasMix: true},
		{WorkloadType: "request", Distributed: true},
		{WorkloadType: "request", ContinuousProfiling: true},
		{WorkloadType: "request", DiagnosticCampaign: true},
		{WorkloadType: "request", Faults: true},
		{WorkloadType: "protocol", HasProtocol: true},
	} {
		got := ProjectLegacyRequestV1(in)
		if got.Eligible {
			t.Fatalf("expected ineligible: %+v", in)
		}
		if err := Inconclusive(got); err == nil {
			t.Fatal("lossy projection must be inconclusive")
		}
	}
}

func assertProjection(t *testing.T, got, want Projection) {
	t.Helper()
	gb, err := json.Marshal(got)
	if err != nil {
		t.Fatal(err)
	}
	wb, err := json.Marshal(want)
	if err != nil {
		t.Fatal(err)
	}
	var gAny, wAny any
	if err := json.Unmarshal(gb, &gAny); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(wb, &wAny); err != nil {
		t.Fatal(err)
	}
	gs, _ := json.Marshal(gAny)
	ws, _ := json.Marshal(wAny)
	if string(gs) != string(ws) {
		t.Fatalf("projection mismatch\ngot  %s\nwant %s", gs, ws)
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
