package performance

import (
	"fmt"

	"github.com/nilshah80/dotnet-perf-eng/capability"
)

func CaptureStates() []string {
	return []string{
		"captured",
		"missing",
		"unsupported",
		"failed",
		"truncated",
		"redacted",
		"delayed",
		"not-applicable",
	}
}

func ActiveRevision() string { return "v1" }

func AdvertiseOrReject(revision, generator, workload string) (capability.Advertisement, error) {
	if err := capability.RejectUnknownRevision(revision); err != nil {
		return capability.Advertisement{}, err
	}
	if revision == "" {
		revision = ActiveRevision()
	}
	return capability.Advertise(revision, generator, workload), nil
}

type Cell struct {
	Generator string            `json:"generator"`
	Workload  string            `json:"workload"`
	Revision  string            `json:"revision"`
	States    map[string]string `json:"states"`
}

func Matrix(revision string) []Cell {
	if revision == "" {
		revision = ActiveRevision()
	}
	var cells []Cell
	for _, generator := range []string{"k6", "jmeter", "wrk"} {
		for _, workload := range []string{"request", "journey"} {
			ad := capability.Advertise(revision, generator, workload)
			out := map[string]string{}
			for key, state := range ad.Capabilities {
				out[key] = string(state)
			}
			cells = append(cells, Cell{Generator: generator, Workload: workload, Revision: revision, States: out})
		}
	}
	return cells
}

func RejectOmittedCaptureState(state string) error {
	if state == "omitted" {
		return fmt.Errorf("capture state omitted is not in the canonical vocabulary")
	}
	for _, allowed := range CaptureStates() {
		if state == allowed {
			return nil
		}
	}
	return fmt.Errorf("unknown capture state %q", state)
}
