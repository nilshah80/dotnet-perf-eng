package performance

import (
	"testing"

	"github.com/nilshah80/dotnet-perf-eng/capability"
)

func TestCaptureStates(t *testing.T) {
	got := CaptureStates()
	if len(got) != 8 {
		t.Fatal(got)
	}
	seen := map[string]bool{}
	for _, state := range got {
		seen[state] = true
	}
	if !seen["redacted"] || seen["omitted"] {
		t.Fatal(got)
	}
	if err := RejectOmittedCaptureState("omitted"); err == nil {
		t.Fatal("omitted must be rejected")
	}
}

func TestAdvertiseDefaultsActive(t *testing.T) {
	ad, err := AdvertiseOrReject("", "k6", "request")
	if err != nil {
		t.Fatal(err)
	}
	if ad.ContractRevision != "v1" {
		t.Fatal(ad.ContractRevision)
	}
	if ad.Capabilities[capability.WorkloadJourney] != capability.Supported {
		t.Fatal(ad.Capabilities[capability.WorkloadJourney])
	}
	if _, err := AdvertiseOrReject("v2", "k6", "request"); err == nil {
		t.Fatal("unknown revision must fail")
	}
}

func TestMatrixHasThreeGenerators(t *testing.T) {
	cells := Matrix("")
	if len(cells) != 6 {
		t.Fatalf("got %d cells", len(cells))
	}
}
