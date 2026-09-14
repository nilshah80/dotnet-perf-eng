package datafault

import "testing"

func TestUniquePartitionPerRun(t *testing.T) {
	p := NewProvider()
	if _, err := p.Seed("run-a", 10, true); err != nil {
		t.Fatal(err)
	}
	if _, err := p.Seed("run-a", 10, true); err == nil {
		t.Fatal("duplicate runId must fail")
	}
	if _, err := p.Seed("run-b", 10, true); err != nil {
		t.Fatal(err)
	}
}

func TestCreatePayReadiness(t *testing.T) {
	p := NewProvider()
	if _, err := p.Seed("run-1", 5, true); err != nil {
		t.Fatal(err)
	}
	if _, err := p.Ready("run-1"); err == nil {
		t.Fatal("seed without reset is not ready")
	}
	if err := p.Reset("run-1"); err != nil {
		t.Fatal(err)
	}
	if _, err := p.Ready("run-1"); err != nil {
		t.Fatal(err)
	}
}

func TestIncompleteCleanupCannotPassGate(t *testing.T) {
	p := NewProvider()
	if _, err := p.Seed("run-1", 5, true); err != nil {
		t.Fatal(err)
	}
	if err := p.Reset("run-1"); err != nil {
		t.Fatal(err)
	}
	if err := p.Gate("run-1"); err == nil {
		t.Fatal("incomplete cleanup must not pass")
	}
	if err := p.Cleanup("run-1"); err != nil {
		t.Fatal(err)
	}
	if err := p.Gate("run-1"); err != nil {
		t.Fatal(err)
	}
}

func TestFaultApplyRestoreProof(t *testing.T) {
	p := NewProvider()
	if _, err := p.Seed("run-1", 5, true); err != nil {
		t.Fatal(err)
	}
	if err := p.Reset("run-1"); err != nil {
		t.Fatal(err)
	}
	if err := p.Cleanup("run-1"); err != nil {
		t.Fatal(err)
	}
	if err := p.ApplyFault("f1", "dependency-pause", ""); err == nil {
		t.Fatal("apply without proof must fail")
	}
	if err := p.ApplyFault("f1", "dependency-pause", "paused"); err != nil {
		t.Fatal(err)
	}
	if err := p.Gate("run-1"); err == nil {
		t.Fatal("applied unrestored fault must fail the gate")
	}
	if err := p.RestoreFault("f1", "resumed"); err != nil {
		t.Fatal(err)
	}
	if err := p.Gate("run-1"); err != nil {
		t.Fatal(err)
	}
}
