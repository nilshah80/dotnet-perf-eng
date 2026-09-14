package session

import "testing"

func TestSoakRejectedWithoutBaseSession(t *testing.T) {
	if err := RejectSoak(NewProbeOnly()); err == nil {
		t.Fatal("probe-only adapter must reject soak")
	}
	if err := RejectSoak(nil); err == nil {
		t.Fatal("nil session must reject soak")
	}
}

func TestStartSnapshotStop(t *testing.T) {
	s := NewBaseSession()
	if err := RejectSoak(s); err != nil {
		t.Fatal(err)
	}
	if err := s.Start("soak-1"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Snapshot("c1", 10, 9, 1); err != nil {
		t.Fatal(err)
	}
	if err := s.Stop(); err != nil {
		t.Fatal(err)
	}
	if !s.Uninterrupted() {
		t.Fatal("soak must stay on one generator session")
	}
}

func TestUpdateLoadOptional(t *testing.T) {
	base := NewBaseSession()
	if err := base.Start("s"); err != nil {
		t.Fatal(err)
	}
	if err := base.Update(12); err == nil {
		t.Fatal("UpdateLoad must be a separate capability")
	}
	updating := NewUpdatingSession()
	if err := updating.Start("s2"); err != nil {
		t.Fatal(err)
	}
	if err := updating.Update(12); err != nil {
		t.Fatal(err)
	}
}

func TestProbeOnlyCannotSnapshot(t *testing.T) {
	s := NewProbeOnly()
	if err := s.Start("x"); err == nil {
		t.Fatal("probe-only Start must fail")
	}
}
