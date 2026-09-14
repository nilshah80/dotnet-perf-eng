package main

import (
	"encoding/csv"
	"fmt"
	"io"
	"math"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
)

type sample struct {
	Start           time.Time
	Elapsed         time.Duration
	Label           string
	ResponseCode    string
	ResponseMessage string
	Success         bool
	Latency         time.Duration
}

type jtlReport struct {
	Samples           []sample
	RequestSamples    []sample
	SHA256            string
	Bytes             int64
	StartedAt         time.Time
	FinishedAt        time.Time
	Succeeded         uint64
	Failed            uint64
	StatusErrors      uint64
	Non2xx            uint64
	Transport         uint64
	JourneyIterations uint64
	JourneySucceeded  uint64
	JourneyFailed     uint64
	JourneyAborted    uint64
	OperationCounts   map[string]uint64
}

func parseJTLFile(path string) (jtlReport, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return jtlReport{}, err
	}
	report, err := parseJTL(strings.NewReader(string(raw)))
	if err != nil {
		return report, err
	}
	report.SHA256 = hashBytes(raw)
	report.Bytes = int64(len(raw))
	return report, nil
}

func parseJTL(r io.Reader) (jtlReport, error) {
	reader := csv.NewReader(r)
	reader.FieldsPerRecord = -1
	reader.ReuseRecord = false
	header, err := reader.Read()
	if err != nil {
		return jtlReport{}, fmt.Errorf("invalid JTL header: %w", err)
	}
	idx, err := columnMap(header)
	if err != nil {
		return jtlReport{}, err
	}
	out := jtlReport{Samples: make([]sample, 0, 64), OperationCounts: map[string]uint64{}}
	line := 1
	for {
		line++
		record, err := reader.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			return out, fmt.Errorf("JTL row %d: %w", line, err)
		}
		row, err := decodeSample(record, idx)
		if err != nil {
			return out, fmt.Errorf("JTL row %d: %w", line, err)
		}
		out.accept(row)
	}
	if len(out.Samples) == 0 {
		return out, fmt.Errorf("JTL contained no samples")
	}
	return out, nil
}

type columns struct {
	timeStamp       int
	elapsed         int
	label           int
	responseCode    int
	responseMessage int
	success         int
	latency         int
}

func columnMap(header []string) (columns, error) {
	idx := columns{timeStamp: -1, elapsed: -1, label: -1, responseCode: -1, responseMessage: -1, success: -1, latency: -1}
	for i, name := range header {
		switch strings.ToLower(strings.TrimSpace(name)) {
		case "timestamp":
			idx.timeStamp = i
		case "elapsed":
			idx.elapsed = i
		case "label":
			idx.label = i
		case "responsecode":
			idx.responseCode = i
		case "responsemessage":
			idx.responseMessage = i
		case "success":
			idx.success = i
		case "latency":
			idx.latency = i
		}
	}
	var missing []string
	if idx.timeStamp < 0 {
		missing = append(missing, "timeStamp")
	}
	if idx.elapsed < 0 {
		missing = append(missing, "elapsed")
	}
	if idx.label < 0 {
		missing = append(missing, "label")
	}
	if idx.responseCode < 0 {
		missing = append(missing, "responseCode")
	}
	if idx.responseMessage < 0 {
		missing = append(missing, "responseMessage")
	}
	if idx.success < 0 {
		missing = append(missing, "success")
	}
	if idx.latency < 0 {
		missing = append(missing, "Latency")
	}
	if len(missing) > 0 {
		return idx, fmt.Errorf("invalid JTL header: missing %s", strings.Join(missing, ", "))
	}
	return idx, nil
}

func decodeSample(record []string, idx columns) (sample, error) {
	need := idx.timeStamp
	for _, pos := range []int{idx.elapsed, idx.label, idx.responseCode, idx.responseMessage, idx.success, idx.latency} {
		if pos > need {
			need = pos
		}
	}
	if len(record) <= need {
		return sample{}, fmt.Errorf("missing required column")
	}
	stamp, err := strconv.ParseInt(strings.TrimSpace(record[idx.timeStamp]), 10, 64)
	if err != nil || stamp <= 0 {
		return sample{}, fmt.Errorf("invalid timeStamp")
	}
	elapsedMs, err := strconv.ParseInt(strings.TrimSpace(record[idx.elapsed]), 10, 64)
	if err != nil || elapsedMs < 0 {
		return sample{}, fmt.Errorf("invalid elapsed")
	}
	ok, err := parseBool(record[idx.success])
	if err != nil {
		return sample{}, err
	}
	latencyMs, err := strconv.ParseInt(strings.TrimSpace(record[idx.latency]), 10, 64)
	if err != nil || latencyMs < 0 {
		return sample{}, fmt.Errorf("invalid Latency")
	}
	return sample{
		Start:           time.UnixMilli(stamp).UTC(),
		Elapsed:         time.Duration(elapsedMs) * time.Millisecond,
		Label:           strings.Clone(record[idx.label]),
		ResponseCode:    strings.Clone(record[idx.responseCode]),
		ResponseMessage: strings.Clone(record[idx.responseMessage]),
		Success:         ok,
		Latency:         time.Duration(latencyMs) * time.Millisecond,
	}, nil
}

func parseBool(raw string) (bool, error) {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "true":
		return true, nil
	case "false":
		return false, nil
	default:
		return false, fmt.Errorf("invalid success value")
	}
}

func classifyLabel(label string) string {
	switch {
	case strings.HasPrefix(label, "journey::"):
		return "parent"
	case strings.HasPrefix(label, "op::"):
		return "child"
	case strings.HasPrefix(label, "control::"):
		return "control"
	default:
		return "request"
	}
}

func (r *jtlReport) accept(row sample) {
	if classifyLabel(row.Label) == "control" {
		return
	}
	r.Samples = append(r.Samples, row)
	end := row.Start.Add(row.Elapsed)
	if r.StartedAt.IsZero() || row.Start.Before(r.StartedAt) {
		r.StartedAt = row.Start
	}
	if r.FinishedAt.IsZero() || end.After(r.FinishedAt) {
		r.FinishedAt = end
	}
	if classifyLabel(row.Label) == "parent" {
		r.JourneyIterations++
		if !completeTransactionMessage(row.ResponseMessage) {
			r.JourneyAborted++
		} else if row.Success {
			r.JourneySucceeded++
		} else {
			r.JourneyFailed++
		}
		return
	}
	if classifyLabel(row.Label) == "child" {
		r.OperationCounts[row.Label]++
	}
	r.RequestSamples = append(r.RequestSamples, row)
	status, numeric := httpStatus(row.ResponseCode)
	if numeric {
		if status < 200 || status >= 300 {
			r.Non2xx++
		}
		if status < 200 || status >= 400 {
			r.StatusErrors++
		}
	} else {
		r.Transport++
	}
	if row.Success && numeric && status >= 200 && status < 400 {
		r.Succeeded++
	} else {
		r.Failed++
	}
}

func completeTransactionMessage(message string) bool {
	message = strings.TrimSpace(message)
	return strings.HasPrefix(message, "Number of samples in transaction : ") &&
		strings.Contains(message, "number of failing samples : ")
}

func httpStatus(code string) (int, bool) {
	code = strings.TrimSpace(code)
	if code == "" {
		return 0, false
	}
	value, err := strconv.Atoi(code)
	if err != nil || value < 100 || value > 599 {
		return 0, false
	}
	return value, true
}

func percentileMs(samples []sample, p float64) float64 {
	if len(samples) == 0 {
		return 0
	}
	values := make([]float64, len(samples))
	for i, s := range samples {
		values[i] = float64(s.Elapsed.Microseconds()) / 1000
	}
	sort.Float64s(values)
	if len(values) == 1 {
		return values[0]
	}
	rank := (p / 100) * float64(len(values)-1)
	lo := int(math.Floor(rank))
	hi := int(math.Ceil(rank))
	if lo == hi {
		return values[lo]
	}
	w := rank - float64(lo)
	return values[lo]*(1-w) + values[hi]*w
}

func meanMs(samples []sample) float64 {
	if len(samples) == 0 {
		return 0
	}
	var sum float64
	for _, s := range samples {
		sum += float64(s.Elapsed.Microseconds()) / 1000
	}
	return sum / float64(len(samples))
}
