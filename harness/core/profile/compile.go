package profile

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
)

type Input struct {
	Kind            string  `json:"kind"`
	WorkloadType    string  `json:"workloadType"`
	Rate            float64 `json:"rate"`
	DurationSeconds int     `json:"durationSeconds"`
	MaxRate         float64 `json:"maxRate,omitempty"`
	SpikeRate       float64 `json:"spikeRate,omitempty"`
	SoakSeconds     int     `json:"soakSeconds,omitempty"`
}

type Stage struct {
	Name            string  `json:"name"`
	Kind            string  `json:"kind"`
	DurationSeconds int     `json:"durationSeconds"`
	Target          float64 `json:"target"`
}

type Compiled struct {
	Name               string   `json:"name"`
	LoadModel          string   `json:"loadModel"`
	RateUnit           string   `json:"rateUnit"`
	SessionRequired    bool     `json:"sessionRequired"`
	UpdateLoadRequired bool     `json:"updateLoadRequired"`
	LastHealthyTarget  *float64 `json:"lastHealthyTarget,omitempty"`
	FirstFailingTarget *float64 `json:"firstFailingTarget,omitempty"`
	Stages             []Stage  `json:"stages"`
}

func Compile(in Input) (Compiled, error) {
	if in.Rate <= 0 {
		in.Rate = 8
	}
	if in.DurationSeconds <= 0 {
		in.DurationSeconds = 30
	}
	if in.WorkloadType == "" {
		in.WorkloadType = "request"
	}
	if in.MaxRate <= 0 {
		in.MaxRate = in.Rate * 2
	}
	if in.SpikeRate <= 0 {
		in.SpikeRate = in.Rate * 4
	}
	if in.SoakSeconds <= 0 {
		in.SoakSeconds = 600
	}
	kind := strings.ToLower(in.Kind)
	unit, model := units(in.WorkloadType, kind)
	out := Compiled{Name: kind, LoadModel: model, RateUnit: unit}
	q := maxInt(in.DurationSeconds/4, 1)
	half := maxInt(in.DurationSeconds/2, 1)
	switch kind {
	case "smoke":
		out.Stages = []Stage{
			{Name: "warmup", Kind: "warmup", DurationSeconds: 2, Target: 1},
			{Name: "measure", Kind: "measure", DurationSeconds: 10, Target: 1},
		}
	case "steady", "load":
		out.Stages = []Stage{
			{Name: "warmup", Kind: "warmup", DurationSeconds: maxInt(in.DurationSeconds/10, 1), Target: in.Rate},
			{Name: "stabilize", Kind: "stabilize", DurationSeconds: maxInt(in.DurationSeconds/10, 1), Target: in.Rate},
			{Name: "measure", Kind: "measure", DurationSeconds: in.DurationSeconds, Target: in.Rate},
		}
	case "ramp":
		out.Stages = []Stage{
			{Name: "ramp-25", Kind: "measure", DurationSeconds: q, Target: atLeast(in.Rate * 0.25)},
			{Name: "ramp-50", Kind: "measure", DurationSeconds: q, Target: atLeast(in.Rate * 0.5)},
			{Name: "ramp-75", Kind: "measure", DurationSeconds: q, Target: atLeast(in.Rate * 0.75)},
			{Name: "ramp-100", Kind: "measure", DurationSeconds: q, Target: in.Rate},
		}
	case "stress":
		out.Stages = []Stage{
			{Name: "expected", Kind: "measure", DurationSeconds: half, Target: in.Rate},
			{Name: "beyond", Kind: "measure", DurationSeconds: half, Target: in.MaxRate},
		}
		last := in.Rate
		first := in.MaxRate
		out.LastHealthyTarget = &last
		out.FirstFailingTarget = &first
	case "breakpoint":
		low := atLeast(in.Rate * 0.5)
		mid := in.Rate
		high := in.MaxRate
		out.Stages = []Stage{
			{Name: "bracket-low", Kind: "measure", DurationSeconds: q, Target: low},
			{Name: "bracket-mid", Kind: "measure", DurationSeconds: q, Target: mid},
			{Name: "bracket-high", Kind: "measure", DurationSeconds: q, Target: high},
			{Name: "narrow", Kind: "measure", DurationSeconds: q, Target: (mid + high) / 2},
		}
		out.LastHealthyTarget = &mid
		out.FirstFailingTarget = &high
	case "spike":
		out.Stages = []Stage{
			{Name: "baseline", Kind: "measure", DurationSeconds: 5, Target: in.Rate},
			{Name: "hold-baseline", Kind: "measure", DurationSeconds: q, Target: in.Rate},
			{Name: "surge", Kind: "measure", DurationSeconds: 5, Target: in.SpikeRate},
			{Name: "hold-surge", Kind: "measure", DurationSeconds: q, Target: in.SpikeRate},
			{Name: "recover", Kind: "recover", DurationSeconds: 5, Target: in.Rate},
			{Name: "hold-recover", Kind: "measure", DurationSeconds: q, Target: in.Rate},
		}
	case "open", "arrival":
		out.LoadModel = "open"
		out.RateUnit = openUnit(in.WorkloadType)
		out.Stages = []Stage{
			{Name: "warmup", Kind: "warmup", DurationSeconds: maxInt(in.DurationSeconds/10, 1), Target: 1},
			{Name: "measure", Kind: "measure", DurationSeconds: in.DurationSeconds, Target: in.Rate},
		}
	case "capacity", "knee":
		out.LoadModel = "open"
		out.RateUnit = openUnit(in.WorkloadType)
		low := atLeast(in.Rate * 0.5)
		high := in.MaxRate
		out.Stages = []Stage{
			{Name: "search-low", Kind: "measure", DurationSeconds: q, Target: low},
			{Name: "search-high", Kind: "measure", DurationSeconds: q, Target: high},
		}
		out.LastHealthyTarget = &low
		out.FirstFailingTarget = &high
	case "closed":
		out.LoadModel = "closed"
		out.RateUnit = closedUnit(in.WorkloadType)
		out.Stages = []Stage{
			{Name: "measure", Kind: "measure", DurationSeconds: in.DurationSeconds, Target: in.Rate},
		}
	case "soak":
		out.SessionRequired = true
		out.UpdateLoadRequired = false
		out.Stages = []Stage{
			{Name: "measure", Kind: "measure", DurationSeconds: in.SoakSeconds, Target: in.Rate},
		}
	default:
		return Compiled{}, fmt.Errorf("unknown profile %q", in.Kind)
	}
	if len(out.Stages) == 0 {
		return Compiled{}, fmt.Errorf("profile %s compiled zero stages", kind)
	}
	return out, nil
}

func Encode(c Compiled) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(c); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func units(workload, kind string) (string, string) {
	switch kind {
	case "open":
		return openUnit(workload), "open"
	default:
		return closedUnit(workload), "closed"
	}
}

func openUnit(workload string) string {
	if workload == "journey" {
		return "journeys/s"
	}
	return "requests/s"
}

func closedUnit(workload string) string {
	if workload == "journey" {
		return "concurrent-users"
	}
	return "concurrent-iterations"
}

func maxInt(v, floor int) int {
	if v > floor {
		return v
	}
	return floor
}

func atLeast(v float64) float64 {
	if v < 1 {
		return 1
	}
	return v
}
