package profile

import (
	"bytes"
	"encoding/json"
	"fmt"
)

type k6Stage struct {
	Duration string `json:"duration"`
	Target   int    `json:"target"`
}

func K6Config(c Compiled, in Input, connections, maxVUs int) ([]byte, error) {
	if connections < 1 {
		connections = 1
	}
	if maxVUs < connections {
		maxVUs = connections * 4
		if maxVUs < 1 {
			maxVUs = 1
		}
	}
	rate := in.Rate
	if rate <= 0 {
		rate = float64(connections)
	}
	measure := map[string]any{}
	if c.LoadModel == "open" {
		if len(c.Stages) == 1 {
			measure["executor"] = "constant-arrival-rate"
			measure["rate"] = int(c.Stages[0].Target)
			if measure["rate"] == 0 {
				measure["rate"] = connections
			}
			measure["timeUnit"] = "1s"
			measure["duration"] = fmt.Sprintf("%ds", c.Stages[0].DurationSeconds)
			measure["preAllocatedVUs"] = connections
			measure["maxVUs"] = maxVUs
		} else {
			measure["executor"] = "ramping-arrival-rate"
			measure["startRate"] = 1
			measure["timeUnit"] = "1s"
			measure["preAllocatedVUs"] = connections
			measure["maxVUs"] = maxVUs
			stages := make([]k6Stage, 0, len(c.Stages))
			for _, stage := range c.Stages {
				stages = append(stages, k6Stage{Duration: fmt.Sprintf("%ds", stage.DurationSeconds), Target: int(stage.Target)})
			}
			measure["stages"] = stages
		}
	} else if c.Name == "soak" || len(c.Stages) == 1 {
		vus := vuTarget(c.Stages[0].Target, rate, connections)
		measure["executor"] = "constant-vus"
		measure["vus"] = vus
		measure["duration"] = fmt.Sprintf("%ds", c.Stages[0].DurationSeconds)
	} else {
		measure["executor"] = "ramping-vus"
		measure["startVUs"] = 0
		measure["gracefulRampDown"] = "0s"
		stages := make([]k6Stage, 0, len(c.Stages))
		for _, stage := range c.Stages {
			stages = append(stages, k6Stage{Duration: fmt.Sprintf("%ds", stage.DurationSeconds), Target: vuTarget(stage.Target, rate, connections)})
		}
		measure["stages"] = stages
	}
	out := map[string]any{
		"scenarios":             map[string]any{"measure": measure},
		"summaryTrendStats":     []string{"avg", "min", "med", "max", "p(50)", "p(90)", "p(95)", "p(99)"},
		"discardResponseBodies": true,
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(out); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func DurationSeconds(c Compiled) int {
	total := 0
	for _, stage := range c.Stages {
		total += stage.DurationSeconds
	}
	return total
}

func vuTarget(stageTarget, rate float64, connections int) int {
	if rate <= 0 {
		if connections < 1 {
			return 1
		}
		return connections
	}
	v := int(float64(connections) * stageTarget / rate)
	if v < 1 {
		return 1
	}
	return v
}
