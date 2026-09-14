package profile

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestGoldenCompiledJSON(t *testing.T) {
	in := Input{WorkloadType: "request", Rate: 8, DurationSeconds: 30, MaxRate: 16, SpikeRate: 32, SoakSeconds: 600}
	dir := filepath.Join("testdata")
	for _, kind := range []string{"smoke", "steady", "ramp", "stress", "breakpoint", "spike", "open", "closed", "soak"} {
		in.Kind = kind
		got, err := Compile(in)
		if err != nil {
			t.Fatalf("%s: %v", kind, err)
		}
		raw, err := Encode(got)
		if err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(dir, kind+".json")
		if os.Getenv("UPDATE_GOLDEN") == "1" {
			if err := os.MkdirAll(dir, 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path, raw, 0o644); err != nil {
				t.Fatal(err)
			}
			continue
		}
		want, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("golden %s: %v", path, err)
		}
		if !bytes.Equal(raw, want) {
			t.Fatalf("%s mismatch\ngot:\n%s\nwant:\n%s", kind, raw, want)
		}
	}
}

func TestSoakRequiresSessionFlag(t *testing.T) {
	got, err := Compile(Input{Kind: "soak", Rate: 8})
	if err != nil {
		t.Fatal(err)
	}
	if !got.SessionRequired || got.UpdateLoadRequired {
		t.Fatalf("soak must require base session only: %+v", got)
	}
}

func TestCanonicalAliasesCompile(t *testing.T) {
	for _, kind := range []string{"load", "arrival", "capacity", "knee"} {
		got, err := Compile(Input{Kind: kind, Rate: 8, DurationSeconds: 30, MaxRate: 16})
		if err != nil {
			t.Fatalf("%s: %v", kind, err)
		}
		if len(got.Stages) == 0 {
			t.Fatalf("%s compiled zero stages", kind)
		}
	}
}

func TestJourneyUnits(t *testing.T) {
	open, err := Compile(Input{Kind: "open", WorkloadType: "journey", Rate: 20})
	if err != nil {
		t.Fatal(err)
	}
	if open.RateUnit != "journeys/s" {
		t.Fatal(open.RateUnit)
	}
	closed, err := Compile(Input{Kind: "closed", WorkloadType: "journey", Rate: 8})
	if err != nil {
		t.Fatal(err)
	}
	if closed.RateUnit != "concurrent-users" {
		t.Fatal(closed.RateUnit)
	}
}

func TestK6ConfigUsesCompiledStages(t *testing.T) {
	in := Input{Kind: "ramp", Rate: 8, DurationSeconds: 30, MaxRate: 16}
	compiled, err := Compile(in)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := K6Config(compiled, in, 8, 32)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(raw, []byte(`"executor":"ramping-vus"`)) && !bytes.Contains(raw, []byte(`"executor": "ramping-vus"`)) {
		t.Fatalf("expected ramping-vus config:\n%s", raw)
	}
	if DurationSeconds(compiled) != 28 {
		t.Fatalf("ramp duration %d", DurationSeconds(compiled))
	}
}
