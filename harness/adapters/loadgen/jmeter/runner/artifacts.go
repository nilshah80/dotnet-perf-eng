package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

type Summary struct {
	ScriptHash        string  `json:"scriptHash"`
	JTLSHA256         string  `json:"jtlSha256,omitempty"`
	JTLBytes          int64   `json:"jtlBytes,omitempty"`
	Requests          uint64  `json:"requests"`
	Iterations        uint64  `json:"iterations,omitempty"`
	JourneySucceeded  uint64  `json:"journeySucceeded,omitempty"`
	JourneyFailed     uint64  `json:"journeyFailed,omitempty"`
	JourneyAborted    uint64  `json:"journeyAborted,omitempty"`
	JourneyChildOps   uint64  `json:"journeyChildOps,omitempty"`
	JourneyWire       uint64  `json:"journeyWireRequests,omitempty"`
	JourneyRetries    uint64  `json:"journeyRetries,omitempty"`
	Succeeded         uint64  `json:"succeeded"`
	Failed            uint64  `json:"failed"`
	StatusErrors      uint64  `json:"statusErrors"`
	Non2xx            uint64  `json:"non2xx"`
	TransportErrors   uint64  `json:"transportErrors"`
	DroppedIterations uint64  `json:"droppedIterations"`
	ErrorRate         float64 `json:"errorRate"`
	RequestsPerSecond float64 `json:"requestsPerSecond"`
	P50Ms             float64 `json:"p50Ms"`
	P90Ms             float64 `json:"p90Ms"`
	P95Ms             float64 `json:"p95Ms"`
	P99Ms             float64 `json:"p99Ms"`
	MeanMs            float64 `json:"meanMs"`
	StartedAt         string  `json:"startedAt,omitempty"`
	FinishedAt        string  `json:"finishedAt,omitempty"`
	AdapterID         string  `json:"adapterId,omitempty"`
	AdapterVersion    string  `json:"adapterVersion,omitempty"`
}

func summarize(report jtlReport, scriptHash string, m Manifest) (Summary, error) {
	requestSamples := report.RequestSamples
	if len(requestSamples) == 0 && report.JourneyIterations == 0 {
		requestSamples = report.Samples
	}
	if len(report.Samples) == 0 {
		return Summary{}, fmt.Errorf("no JTL samples to summarize")
	}
	if report.FinishedAt.Before(report.StartedAt) || !report.FinishedAt.After(report.StartedAt) {
		return Summary{}, fmt.Errorf("JTL window has no duration")
	}
	window := report.FinishedAt.Sub(report.StartedAt).Seconds()
	summary := Summary{
		ScriptHash:        scriptHash,
		JTLSHA256:         report.SHA256,
		JTLBytes:          report.Bytes,
		Requests:          uint64(len(requestSamples)),
		Iterations:        report.JourneyIterations,
		JourneySucceeded:  report.JourneySucceeded,
		JourneyFailed:     report.JourneyFailed,
		JourneyAborted:    report.JourneyAborted,
		Succeeded:         report.Succeeded,
		Failed:            report.Failed,
		StatusErrors:      report.StatusErrors,
		Non2xx:            report.Non2xx,
		TransportErrors:   report.Transport,
		DroppedIterations: 0,
		P50Ms:             percentileMs(requestSamples, 50),
		P90Ms:             percentileMs(requestSamples, 90),
		P95Ms:             percentileMs(requestSamples, 95),
		P99Ms:             percentileMs(requestSamples, 99),
		MeanMs:            meanMs(requestSamples),
		StartedAt:         report.StartedAt.UTC().Format(time.RFC3339Nano),
		FinishedAt:        report.FinishedAt.UTC().Format(time.RFC3339Nano),
		AdapterID:         m.AdapterID,
		AdapterVersion:    m.AdapterVersion,
	}
	if summary.Iterations == 0 {
		summary.Iterations = summary.Requests
	} else if summary.JourneySucceeded+summary.JourneyFailed+summary.JourneyAborted != summary.Iterations {
		return Summary{}, fmt.Errorf("journey outcomes do not reconcile")
	}
	if report.JourneyIterations > 0 {
		summary.JourneyWire = summary.Requests
		polls := report.OperationCounts["op::poll"]
		journeysAtPoll := report.OperationCounts["op::pay"]
		if polls > journeysAtPoll {
			summary.JourneyRetries = polls - journeysAtPoll
		}
		summary.JourneyChildOps = summary.JourneyWire - summary.JourneyRetries
	}
	summary.RequestsPerSecond = float64(summary.Requests) / window
	if summary.Requests > 0 {
		summary.ErrorRate = float64(summary.Failed) / float64(summary.Requests)
	}
	return summary, nil
}

func (s Summary) observations() []map[string]any {
	src := "benchmark/jmeter-summary-v1.json"
	obs := []map[string]any{
		observation("http.requests_per_second", s.RequestsPerSecond, "request/s", src),
		observation("http.latency.p50", s.P50Ms, "ms", src),
		observation("http.latency.p90", s.P90Ms, "ms", src),
		observation("http.latency.p95", s.P95Ms, "ms", src),
		observation("http.latency.p99", s.P99Ms, "ms", src),
		observation("http.requests.total", s.Requests, "request", src),
		observation("http.responses.non_2xx_3xx", s.StatusErrors, "response", src),
		observation("http.transport_errors", s.TransportErrors, "error", src),
		observation("http.error_rate", s.ErrorRate, "ratio", src),
		observation("http.dropped_iterations", s.DroppedIterations, "iteration", src),
	}
	if s.Iterations > 0 && s.Iterations != s.Requests {
		obs = append(obs,
			observation("journeys.started", s.Iterations, "journey", src),
			observation("journeys.completed", s.JourneySucceeded, "journey", src),
			observation("journeys.failed", s.JourneyFailed, "journey", src),
			observation("journeys.aborted", s.JourneyAborted, "journey", src),
			observation("journeys.child_ops", s.JourneyChildOps, "operation", src),
			observation("journeys.wire_requests", s.JourneyWire, "request", src),
			observation("journeys.retries", s.JourneyRetries, "request", src),
			observation("journeys.request_amplification", journeyAmplification(s), "request/journey", src),
		)
	}
	return obs
}

func journeyAmplification(s Summary) float64 {
	if s.Iterations == 0 {
		return 0
	}
	return float64(s.JourneyWire) / float64(s.Iterations)
}

func observation(name string, value any, unit, source string) map[string]any {
	return map[string]any{"name": name, "value": value, "unit": unit, "source": source}
}

func summaryFile(phase string) string {
	switch phase {
	case "warmup":
		return "jmeter-warmup-summary-v1.json"
	case "diagnostic":
		return "jmeter-diagnostic-summary-v1.json"
	default:
		return "jmeter-summary-v1.json"
	}
}

func jtlFile(phase string) string {
	switch phase {
	case "warmup":
		return "warmup-results.jtl"
	case "diagnostic":
		return "diagnostic-results.jtl"
	default:
		return "results.jtl"
	}
}

func publish(outputDir, phase string, summary Summary, writeObs bool) error {
	bench := filepath.Join(outputDir, "benchmark")
	if err := os.MkdirAll(bench, 0o750); err != nil {
		return err
	}
	if err := writeJSON(filepath.Join(bench, summaryFile(phase)), summary); err != nil {
		return err
	}
	if writeObs {
		if err := writeJSON(filepath.Join(bench, "observations.json"), summary.observations()); err != nil {
			return err
		}
	}
	return nil
}

func writeJSON(path string, value any) error {
	raw, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	raw = append(raw, '\n')
	return writeAtomic(path, raw)
}

func writeAtomic(path string, content []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, content, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func copyFile(src, dst string) error {
	raw, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return writeAtomic(dst, raw)
}
