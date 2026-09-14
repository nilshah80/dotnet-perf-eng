package main

import (
	"fmt"
	"path/filepath"
	"strings"
	"time"
)

type invocation struct {
	WorkloadRoot string
	Plan         string
	Files        []string
	JTL          string
	OutputDir    string
	Phase        string
	Timeout      time.Duration
}

func parseFlags(args []string, needPhase, needJTL bool) (invocation, error) {
	in := invocation{}
	for i := 0; i < len(args); i++ {
		arg := args[i]
		needValue := func() (string, error) {
			if i+1 >= len(args) {
				return "", fmt.Errorf("flag %s requires a value", arg)
			}
			i++
			return args[i], nil
		}
		switch arg {
		case "--workload-root":
			value, err := needValue()
			if err != nil {
				return in, err
			}
			in.WorkloadRoot = value
		case "--plan":
			value, err := needValue()
			if err != nil {
				return in, err
			}
			in.Plan = value
		case "--file":
			value, err := needValue()
			if err != nil {
				return in, err
			}
			in.Files = append(in.Files, value)
		case "--jtl":
			value, err := needValue()
			if err != nil {
				return in, err
			}
			in.JTL = value
		case "--output-dir":
			value, err := needValue()
			if err != nil {
				return in, err
			}
			in.OutputDir = value
		case "--phase":
			value, err := needValue()
			if err != nil {
				return in, err
			}
			in.Phase = value
		case "--timeout":
			value, err := needValue()
			if err != nil {
				return in, err
			}
			d, err := time.ParseDuration(value)
			if err != nil || d <= 0 {
				return in, fmt.Errorf("timeout must be a positive Go duration")
			}
			in.Timeout = d
		default:
			return in, fmt.Errorf("unknown flag %q", arg)
		}
	}
	if strings.TrimSpace(in.OutputDir) == "" {
		return in, fmt.Errorf("--output-dir is required")
	}
	if needJTL && strings.TrimSpace(in.JTL) == "" {
		return in, fmt.Errorf("--jtl is required")
	}
	if needPhase {
		switch in.Phase {
		case "warmup", "measure", "diagnostic":
		default:
			return in, fmt.Errorf("--phase must be warmup, measure, or diagnostic")
		}
		if in.Timeout <= 0 {
			return in, fmt.Errorf("--timeout is required")
		}
		if strings.TrimSpace(in.WorkloadRoot) == "" || strings.TrimSpace(in.Plan) == "" {
			return in, fmt.Errorf("--workload-root and --plan are required")
		}
	}
	return in, nil
}

func confinedRel(value string) (string, error) {
	trimmed := strings.TrimSpace(value)
	clean := filepath.ToSlash(filepath.Clean(trimmed))
	if trimmed == "" || clean == "." || clean == ".." || filepath.IsAbs(trimmed) || strings.HasPrefix(clean, "../") {
		return "", fmt.Errorf("path %q escapes the workload root", value)
	}
	if strings.Contains(trimmed, `\`) {
		return "", fmt.Errorf("path %q must be slash-separated", value)
	}
	return clean, nil
}

func inventory(plan string, extra []string) ([]string, error) {
	files := []string{}
	seen := map[string]bool{}
	add := func(rel string) error {
		clean, err := confinedRel(rel)
		if err != nil {
			return err
		}
		if seen[clean] {
			return nil
		}
		seen[clean] = true
		files = append(files, clean)
		return nil
	}
	if strings.TrimSpace(plan) != "" {
		if err := add(plan); err != nil {
			return nil, err
		}
	}
	for _, file := range extra {
		if err := add(file); err != nil {
			return nil, err
		}
	}
	return files, nil
}
