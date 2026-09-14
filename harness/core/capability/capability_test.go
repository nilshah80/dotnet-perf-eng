package capability

import (
	"strings"
	"testing"
)

func TestWrkJourneyRejectedBeforeTraffic(t *testing.T) {
	if err := RejectUnsupported("wrk", "journey"); err == nil {
		t.Fatal("expected wrk journey rejection")
	} else if !strings.Contains(err.Error(), "before traffic") {
		t.Fatal(err)
	}
	if err := RejectUnsupported("k6", "journey"); err != nil {
		t.Fatal(err)
	}
	if err := RejectUnsupported("jmeter", "journey"); err != nil {
		t.Fatal(err)
	}
}

func TestAdvertiseJSON(t *testing.T) {
	for _, generator := range []string{"k6", "jmeter", "wrk"} {
		ad := Advertise("v1", generator, "request")
		raw, err := Encode(ad)
		if err != nil {
			t.Fatal(err)
		}
		text := string(raw)
		if !strings.Contains(text, `"generator.wrk.journey": "unsupported"`) {
			t.Fatalf("%s missing wrk journey unsupported:\n%s", generator, text)
		}
		if !strings.Contains(text, `"generator.k6.request": "supported"`) {
			t.Fatal(text)
		}
		if !strings.Contains(text, `"generator.jmeter.request": "supported"`) {
			t.Fatal(text)
		}
		if generator == "k6" && ad.Capabilities[WorkloadJourney] != Supported {
			t.Fatal(ad.Capabilities[WorkloadJourney])
		}
		if generator == "wrk" && Allows(ad, WorkloadJourney) {
			t.Fatal("wrk must not advertise journey")
		}
	}
}

func TestStableRevisionIsExact(t *testing.T) {
	if _, err := ParseRevisionNumber("v01"); err == nil {
		t.Fatal("noncanonical revisions must fail")
	}
	if RevisionAtLeast("v1", 10) {
		t.Fatal("v1 must not satisfy min 10")
	}
	if err := RejectUnknownRevision("v2"); err == nil {
		t.Fatal("unknown revision must fail")
	}
}

func TestMissingCapabilityMeansUnsupported(t *testing.T) {
	ad := Advertise("v1", "k6", "request")
	if Allows(ad, "generator.browser.journey") {
		t.Fatal("missing identifiers are unsupported")
	}
}
