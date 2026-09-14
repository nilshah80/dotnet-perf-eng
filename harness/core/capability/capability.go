package capability

import (
	"bytes"
	"encoding/json"
	"fmt"
	"sort"
)

const (
	WorkloadRequest             = "workload.request"
	WorkloadJourney             = "workload.journey"
	WorkloadMixHomogeneous      = "workload.mix.homogeneous"
	GeneratorK6Request          = "generator.k6.request"
	GeneratorJMeterRequest      = "generator.jmeter.request"
	GeneratorWrkRequest         = "generator.wrk.request"
	GeneratorWrkJourney         = "generator.wrk.journey"
	SessionStartSnapshotStop    = "session.start-snapshot-stop"
	SessionUpdateLoad           = "session.update-load"
	WriteSafetyManagedReference = "writeSafety.managed-reference"
)

type State string

const (
	Supported    State = "supported"
	Experimental State = "experimental"
	Unsupported  State = "unsupported"
)

type Advertisement struct {
	Generator        string           `json:"generator"`
	ContractRevision string           `json:"contractRevision"`
	Workload         string           `json:"workload,omitempty"`
	Capabilities     map[string]State `json:"capabilities"`
}

func Advertise(revision, generator, workload string) Advertisement {
	if revision == "" {
		revision = "v1"
	}
	states := map[string]State{
		WorkloadRequest:             Supported,
		WorkloadMixHomogeneous:      Supported,
		GeneratorK6Request:          Supported,
		GeneratorJMeterRequest:      Supported,
		GeneratorWrkRequest:         Supported,
		GeneratorWrkJourney:         Unsupported,
		WorkloadJourney:             Unsupported,
		WriteSafetyManagedReference: Supported,
		SessionUpdateLoad:           Unsupported,
	}
	if generator != "wrk" {
		states[WorkloadJourney] = Supported
	}
	if generator == "wrk" && (workload == "journey" || workload == "mix") {
		states[GeneratorWrkJourney] = Unsupported
		states[WorkloadJourney] = Unsupported
	}
	if generator == "jmeter" {
		states["generator.jmeter.journey"] = Supported
	}
	if generator == "wrk" {
		states[SessionStartSnapshotStop] = Unsupported
	} else {
		states[SessionStartSnapshotStop] = Supported
	}
	return Advertisement{
		Generator:        generator,
		ContractRevision: revision,
		Workload:         workload,
		Capabilities:     states,
	}
}

func Encode(ad Advertisement) ([]byte, error) {
	keys := make([]string, 0, len(ad.Capabilities))
	for key := range ad.Capabilities {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	ordered := make(map[string]State, len(keys))
	for _, key := range keys {
		ordered[key] = ad.Capabilities[key]
	}
	ad.Capabilities = ordered
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(ad); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func RejectUnsupported(generator, workload string) error {
	if generator == "wrk" && (workload == "journey" || workload == "mix") {
		return fmt.Errorf("capability %s is unsupported for wrk; rejected before traffic", GeneratorWrkJourney)
	}
	return nil
}

func Allows(ad Advertisement, id string) bool {
	state := ad.Capabilities[id]
	return state == Supported || state == Experimental
}
