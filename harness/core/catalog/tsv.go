package catalog

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
)

// TSVRow is the eight-column v1 scenario line used by the native harness.
type TSVRow struct {
	ID          string
	Name        string
	Method      string
	Path        string
	Body        string
	Target      string
	Diagnostic  string
	Connections int
}

func LoadTSV(path string) ([]TSVRow, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	var rows []TSVRow
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	lineNo := 0
	for scanner.Scan() {
		lineNo++
		line := scanner.Text()
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		fields := strings.Split(line, "\t")
		if len(fields) < 8 {
			return nil, fmt.Errorf("%s:%d: expected 8 tab-separated columns, found %d", path, lineNo, len(fields))
		}
		connections, err := strconv.Atoi(strings.TrimSpace(fields[7]))
		if err != nil {
			return nil, fmt.Errorf("%s:%d: connections: %w", path, lineNo, err)
		}
		rows = append(rows, TSVRow{
			ID:          strings.TrimSpace(fields[0]),
			Name:        strings.TrimSpace(fields[1]),
			Method:      strings.TrimSpace(fields[2]),
			Path:        strings.TrimSpace(fields[3]),
			Body:        fields[4],
			Target:      strings.TrimSpace(fields[5]),
			Diagnostic:  strings.TrimSpace(fields[6]),
			Connections: connections,
		})
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("%s: no scenario rows", path)
	}
	return rows, nil
}

// FromTSV adapts v1 TSV rows to request-only catalog entries. Method and path
// stay on the TSV/workload assets; the catalog records intent only.
func FromTSV(rows []TSVRow) ScenarioCatalog {
	out := ScenarioCatalog{
		APIVersion:       APIVersion,
		Kind:             KindCatalog,
		ContractRevision: ActiveRevision,
		Scenarios:        make([]Scenario, 0, len(rows)),
	}
	for _, row := range rows {
		loadModel := "open"
		rate := 0.0
		rateUnit := "requests/s"
		if row.Connections > 0 {
			loadModel = "closed"
			rate = float64(row.Connections)
			rateUnit = "concurrent-iterations"
		}
		classification := "read"
		method := strings.ToUpper(row.Method)
		switch method {
		case "POST", "PUT", "PATCH", "DELETE":
			classification = "write"
		}
		scenario := Scenario{
			ID:   row.ID,
			Name: row.Name,
			Workload: WorkloadRef{
				Type:     "request",
				Selector: row.ID,
			},
			Effects: &Effects{Classification: classification},
			Defaults: &Defaults{
				LoadModel: loadModel,
				Rate:      rate,
				RateUnit:  rateUnit,
			},
			Lifecycle:   &Lifecycle{Ownership: "managed"},
			WriteSafety: &WriteSafety{Class: "none"},
		}
		if row.Name == "" {
			scenario.Name = row.ID
		}
		if row.Target != "" {
			scenario.Targets = []string{row.Target}
		}
		if row.Diagnostic != "" {
			scenario.Diagnostics = &Diagnostics{Preset: row.Diagnostic}
		}
		out.Scenarios = append(out.Scenarios, scenario)
	}
	return out
}

func MigrateTSVFile(tsvPath string) (ScenarioCatalog, []byte, error) {
	rows, err := LoadTSV(tsvPath)
	if err != nil {
		return ScenarioCatalog{}, nil, err
	}
	catalog := FromTSV(rows)
	if err := Validate(catalog); err != nil {
		return ScenarioCatalog{}, nil, err
	}
	raw, err := Encode(catalog)
	if err != nil {
		return ScenarioCatalog{}, nil, err
	}
	return catalog, raw, nil
}

// LookupV1Field synthesizes the eight-column TSV view used by common.sh.
func LookupV1Field(catalog ScenarioCatalog, rows []TSVRow, id, field string) (string, error) {
	for _, row := range rows {
		if row.ID != id {
			continue
		}
		switch field {
		case "id":
			return row.ID, nil
		case "name":
			return row.Name, nil
		case "method":
			return row.Method, nil
		case "path":
			return row.Path, nil
		case "body":
			return row.Body, nil
		case "target":
			return row.Target, nil
		case "diagnostic":
			return row.Diagnostic, nil
		case "connections":
			return strconv.Itoa(row.Connections), nil
		case "type":
			return "request", nil
		case "selector":
			return row.ID, nil
		}
	}
	scenario, ok := Find(catalog, id)
	if !ok {
		return "", fmt.Errorf("unknown scenario %q", id)
	}
	switch field {
	case "id":
		return scenario.ID, nil
	case "name":
		return scenario.Name, nil
	case "method":
		if scenario.Workload.Type == "journey" {
			return "JOURNEY", nil
		}
		if scenario.Workload.Type == "mix" {
			return "MIX", nil
		}
		return "GET", nil
	case "path":
		return "", nil
	case "body":
		return "", nil
	case "target":
		if len(scenario.Targets) > 0 {
			return scenario.Targets[0], nil
		}
		return "", nil
	case "diagnostic":
		if scenario.Diagnostics != nil && scenario.Diagnostics.Preset != "" {
			return scenario.Diagnostics.Preset, nil
		}
		if scenario.Diagnostics != nil && len(scenario.Diagnostics.Targets) > 0 {
			return scenario.Diagnostics.Targets[0], nil
		}
		return "trace", nil
	case "connections":
		if scenario.Defaults != nil && scenario.Defaults.Rate > 0 {
			return strconv.Itoa(int(scenario.Defaults.Rate)), nil
		}
		return "1", nil
	case "type":
		return scenario.Workload.Type, nil
	case "selector":
		return scenario.Workload.Selector, nil
	case "rateUnit":
		if scenario.Defaults != nil {
			return scenario.Defaults.RateUnit, nil
		}
		return "", nil
	case "loadModel":
		if scenario.Defaults != nil {
			return scenario.Defaults.LoadModel, nil
		}
		return "", nil
	case "ownership":
		if scenario.Lifecycle != nil {
			return scenario.Lifecycle.Ownership, nil
		}
		return "none", nil
	case "writeSafety":
		if scenario.WriteSafety != nil {
			return scenario.WriteSafety.Class, nil
		}
		return "none", nil
	default:
		return "", fmt.Errorf("unknown scenario field %q", field)
	}
}

func IDs(catalog ScenarioCatalog) []string {
	ids := make([]string, 0, len(catalog.Scenarios))
	for _, scenario := range catalog.Scenarios {
		ids = append(ids, scenario.ID)
	}
	return ids
}
