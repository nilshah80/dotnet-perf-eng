package datafault

import (
	"fmt"
	"sync"
	"time"
)

type Partition struct {
	RunID        string
	Seeded       bool
	Reset        bool
	Reconciled   bool
	Cleaned      bool
	Acknowledged bool
	Budget       int
	CreatedAt    time.Time
}

type FaultRecord struct {
	ID        string
	Kind      string
	Applied   bool
	Restored  bool
	Proof     string
	ApplyAt   time.Time
	RestoreAt time.Time
}

type Provider struct {
	mu         sync.Mutex
	partitions map[string]*Partition
	faults     map[string]*FaultRecord
}

func NewProvider() *Provider {
	return &Provider{
		partitions: map[string]*Partition{},
		faults:     map[string]*FaultRecord{},
	}
}

func (p *Provider) Seed(runID string, budget int, ack bool) (*Partition, error) {
	if runID == "" {
		return nil, fmt.Errorf("runId is required")
	}
	if budget <= 0 {
		return nil, fmt.Errorf("write budget must be positive")
	}
	if !ack {
		return nil, fmt.Errorf("managed-reference writes require acknowledgement")
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if existing, ok := p.partitions[runID]; ok {
		return nil, fmt.Errorf("partition %s already exists (must be unique per runId)", existing.RunID)
	}
	part := &Partition{RunID: runID, Seeded: true, Acknowledged: true, Budget: budget, CreatedAt: time.Now().UTC()}
	p.partitions[runID] = part
	return part, nil
}

func (p *Provider) Reset(runID string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	part, ok := p.partitions[runID]
	if !ok || !part.Seeded {
		return fmt.Errorf("reset rejected: partition %s is absent or mismatched", runID)
	}
	part.Reset = true
	return nil
}

func (p *Provider) Reconcile(runID string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	part, ok := p.partitions[runID]
	if !ok {
		return fmt.Errorf("reconcile rejected: partition %s is absent", runID)
	}
	part.Reconciled = true
	return nil
}

func (p *Provider) Cleanup(runID string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	part, ok := p.partitions[runID]
	if !ok {
		return fmt.Errorf("cleanup rejected: partition %s is absent", runID)
	}
	part.Cleaned = true
	return nil
}

func (p *Provider) Ready(runID string) (*Partition, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	part, ok := p.partitions[runID]
	if !ok {
		return nil, fmt.Errorf("partition %s is not ready", runID)
	}
	if !part.Seeded || !part.Reset || !part.Acknowledged || part.Budget <= 0 {
		return nil, fmt.Errorf("partition %s missing seed/reset/ack/budget", runID)
	}
	return part, nil
}

func (p *Provider) Gate(runID string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	part, ok := p.partitions[runID]
	if !ok {
		return fmt.Errorf("gate inconclusive: partition %s missing", runID)
	}
	if !part.Cleaned {
		return fmt.Errorf("gate cannot pass: cleanup for %s is incomplete", runID)
	}
	for id, fault := range p.faults {
		if fault.Applied && !fault.Restored {
			return fmt.Errorf("gate cannot pass: fault %s applied without restore proof", id)
		}
		if fault.Applied && fault.Proof == "" {
			return fmt.Errorf("gate cannot pass: fault %s missing apply/restore proof", id)
		}
	}
	return nil
}

func (p *Provider) ApplyFault(id, kind, proof string) error {
	if id == "" || kind == "" {
		return fmt.Errorf("fault id and kind are required")
	}
	if proof == "" {
		return fmt.Errorf("fault apply requires proof")
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	p.faults[id] = &FaultRecord{ID: id, Kind: kind, Applied: true, Proof: proof, ApplyAt: time.Now().UTC()}
	return nil
}

func (p *Provider) RestoreFault(id, proof string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	fault, ok := p.faults[id]
	if !ok || !fault.Applied {
		return fmt.Errorf("restore rejected: fault %s was not applied", id)
	}
	if proof == "" {
		return fmt.Errorf("fault restore requires proof")
	}
	fault.Restored = true
	fault.Proof = fault.Proof + "|" + proof
	fault.RestoreAt = time.Now().UTC()
	return nil
}
