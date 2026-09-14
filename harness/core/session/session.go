package session

import "fmt"

type State string

const (
	Idle     State = "idle"
	Running  State = "running"
	Stopping State = "stopping"
	Stopped  State = "stopped"
)

type Snapshot struct {
	Cursor            string `json:"cursor"`
	Started           int64  `json:"started"`
	Completed         int64  `json:"completed"`
	Failed            int64  `json:"failed"`
	GeneratorRestarts int    `json:"generatorRestarts"`
}

type LoadSession struct {
	ID          string
	State       State
	Probe       bool
	BaseSession bool
	UpdateLoad  bool
	Snapshots   []Snapshot
	Restarts    int
}

func NewProbeOnly() *LoadSession {
	return &LoadSession{Probe: true, State: Idle}
}

func NewBaseSession() *LoadSession {
	return &LoadSession{Probe: true, BaseSession: true, State: Idle}
}

func NewUpdatingSession() *LoadSession {
	return &LoadSession{Probe: true, BaseSession: true, UpdateLoad: true, State: Idle}
}

func RejectSoak(s *LoadSession) error {
	if s == nil || !s.BaseSession {
		return fmt.Errorf("soak rejected before traffic: adapter is missing Start/Snapshot/Stop")
	}
	return nil
}

func RejectChangingLoad(s *LoadSession) error {
	if s == nil || !s.UpdateLoad {
		return fmt.Errorf("in-session load update rejected: UpdateLoad capability is absent")
	}
	if err := RejectSoak(s); err != nil {
		return err
	}
	return nil
}

func (s *LoadSession) Start(id string) error {
	if s == nil || !s.BaseSession {
		return fmt.Errorf("Start is not advertised")
	}
	if s.State == Running {
		return fmt.Errorf("session already running")
	}
	s.ID = id
	s.State = Running
	s.Snapshots = nil
	s.Restarts = 0
	return nil
}

func (s *LoadSession) Snapshot(cursor string, started, completed, failed int64) (Snapshot, error) {
	if s == nil || !s.BaseSession {
		return Snapshot{}, fmt.Errorf("Snapshot is not advertised")
	}
	if s.State != Running {
		return Snapshot{}, fmt.Errorf("snapshot requires a running session")
	}
	snap := Snapshot{Cursor: cursor, Started: started, Completed: completed, Failed: failed, GeneratorRestarts: s.Restarts}
	s.Snapshots = append(s.Snapshots, snap)
	return snap, nil
}

func (s *LoadSession) Update(rate float64) error {
	if err := RejectChangingLoad(s); err != nil {
		return err
	}
	if s.State != Running {
		return fmt.Errorf("UpdateLoad requires a running session")
	}
	if rate <= 0 {
		return fmt.Errorf("rate must be positive")
	}
	return nil
}

func (s *LoadSession) Stop() error {
	if s == nil || !s.BaseSession {
		return fmt.Errorf("Stop is not advertised")
	}
	if s.State != Running {
		return fmt.Errorf("stop requires a running session")
	}
	s.State = Stopped
	return nil
}

func (s *LoadSession) Uninterrupted() bool {
	return s != nil && s.Restarts == 0 && len(s.Snapshots) > 0
}
