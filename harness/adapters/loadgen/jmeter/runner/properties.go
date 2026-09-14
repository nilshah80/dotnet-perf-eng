package main

import (
	"fmt"
	"os"
	"strings"
)

const (
	propBaseURL  = "perf.base_url"
	propThreads  = "perf.threads"
	propDuration = "perf.duration_seconds"
	propRunID    = "perf.run_id"
	propScenario = "perf.scenario"
)

var v1PropertyAdapter = map[string]string{
	"perflab.base_url":         propBaseURL,
	"perflab.threads":          propThreads,
	"perflab.duration_seconds": propDuration,
	"perflab.run_id":           propRunID,
	"perflab.scenario":         propScenario,
}

// AdaptedProperty is one JMeter -J binding after the v1 compatibility adapter.
type AdaptedProperty struct {
	Requested string
	Canonical string
	Legacy    bool
	Value     string
}

// AdaptPropertyName maps a recorded v1 perflab.* key onto the canonical perf.*
// name. Canonical names pass through unchanged.
func AdaptPropertyName(name string) (canonical string, legacy bool) {
	name = strings.TrimSpace(name)
	if mapped, ok := v1PropertyAdapter[name]; ok {
		return mapped, true
	}
	return name, false
}

func defaultPropertyNames() map[string]string {
	return map[string]string{
		"PERFLAB_JMETER_PROP_BASE_URL":         envOr("PERFLAB_JMETER_PROP_BASE_URL", propBaseURL),
		"PERFLAB_JMETER_PROP_THREADS":          envOr("PERFLAB_JMETER_PROP_THREADS", propThreads),
		"PERFLAB_JMETER_PROP_DURATION_SECONDS": envOr("PERFLAB_JMETER_PROP_DURATION_SECONDS", propDuration),
		"PERFLAB_JMETER_PROP_RUN_ID":           envOr("PERFLAB_JMETER_PROP_RUN_ID", propRunID),
		"PERFLAB_JMETER_PROP_SCENARIO":         envOr("PERFLAB_JMETER_PROP_SCENARIO", propScenario),
	}
}

func envOr(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}

func propertyValueEnv(propEnv string) string {
	switch propEnv {
	case "PERFLAB_JMETER_PROP_BASE_URL":
		return strings.TrimSpace(os.Getenv("PERF_BASE_URL"))
	case "PERFLAB_JMETER_PROP_THREADS":
		return strings.TrimSpace(os.Getenv("PERFLAB_CONNECTIONS"))
	case "PERFLAB_JMETER_PROP_DURATION_SECONDS":
		return strings.TrimSpace(os.Getenv("PERFLAB_DURATION_SECONDS"))
	case "PERFLAB_JMETER_PROP_RUN_ID":
		return strings.TrimSpace(os.Getenv("PERF_RUN_ID"))
	case "PERFLAB_JMETER_PROP_SCENARIO":
		return strings.TrimSpace(os.Getenv("PERF_SCENARIO"))
	default:
		return ""
	}
}

// RunProperties builds the -J map for a launch. Canonical perf.* keys are
// always present when a value exists. A requested perflab.* name is also
// emitted so existing v1 JMX files keep working, and Legacy is recorded.
func RunProperties() []AdaptedProperty {
	names := defaultPropertyNames()
	order := []string{
		"PERFLAB_JMETER_PROP_BASE_URL",
		"PERFLAB_JMETER_PROP_THREADS",
		"PERFLAB_JMETER_PROP_DURATION_SECONDS",
		"PERFLAB_JMETER_PROP_RUN_ID",
		"PERFLAB_JMETER_PROP_SCENARIO",
	}
	out := make([]AdaptedProperty, 0, len(order))
	for _, envName := range order {
		requested := names[envName]
		value := propertyValueEnv(envName)
		if value == "" {
			continue
		}
		canonical, legacy := AdaptPropertyName(requested)
		out = append(out, AdaptedProperty{
			Requested: requested,
			Canonical: canonical,
			Legacy:    legacy,
			Value:     value,
		})
	}
	return out
}

func javaPropertyMap(bindings []AdaptedProperty) map[string]string {
	props := map[string]string{}
	for _, binding := range bindings {
		props[binding.Canonical] = binding.Value
		if binding.Legacy {
			props[binding.Requested] = binding.Value
		}
	}
	return props
}

func describeLegacy(bindings []AdaptedProperty) []string {
	var used []string
	for _, binding := range bindings {
		if binding.Legacy {
			used = append(used, fmt.Sprintf("%s->%s", binding.Requested, binding.Canonical))
		}
	}
	return used
}
