package performance

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"time"
)

var RequiredProfileTypes = []string{"cpu", "wall", "allocation", "lock", "exception", "live-heap"}
var profilingCaptureStates = []string{"captured", "missing", "unsupported", "failed", "truncated", "redacted", "delayed", "not-applicable"}

var profilingPolicies = map[string][]string{
	"cpu":            {"cpu"},
	"cpu-wall":       {"cpu", "wall"},
	"memory":         {"allocation", "live-heap"},
	"contention":     {"lock"},
	"exceptions":     {"exception"},
	"soak-memory":    {"allocation", "live-heap"},
	"all-diagnostic": {"cpu", "wall", "allocation", "lock", "exception", "live-heap"},
}

type ProfilingPolicy struct {
	Types          []string
	StaticPhase    string
	QuotaCores     float64
	ThresholdCores float64
	Labels         map[string]string
	ReadOnlyVerify bool
	Unmanaged      bool
	Provider       ProviderDescriptor
	VerifiedAt     time.Time
}

type ProviderDescriptor struct {
	ID                       string   `json:"id"`
	Version                  string   `json:"version"`
	Source                   string   `json:"source"`
	MinimumEffectiveCPUCores float64  `json:"minimumEffectiveCpuCores"`
	ThresholdOverrideAllowed bool     `json:"thresholdOverrideAllowed"`
	ThresholdOverrideMin     float64  `json:"thresholdOverrideMin,omitempty"`
	ThresholdOverrideMax     float64  `json:"thresholdOverrideMax,omitempty"`
	SupportedTypes           []string `json:"supportedTypes"`
}

type ProfilingService struct {
	EffectiveCPUCores float64  `json:"effectiveCpuCores"`
	QuotaSource       string   `json:"quotaSource"`
	ActiveTypes       []string `json:"activeTypes,omitempty"`
	ActivationProbe   string   `json:"activationProbe,omitempty"`
}

type ProfilingSettings struct {
	Provider        ProviderDescriptor          `json:"provider"`
	Services        map[string]ProfilingService `json:"services"`
	ThresholdCores  float64                     `json:"thresholdCores"`
	VerificationURL string                      `json:"verificationUrl,omitempty"`
}

type ProfilingVerification struct {
	VerifiedAt time.Time         `json:"verifiedAt"`
	Profiling  ProfilingSettings `json:"profiling"`
}

var DefaultProfilingProvider = ProviderDescriptor{
	ID: "pyroscope-dotnet", Version: "1.5.1",
	Source:                   "https://github.com/grafana/pyroscope-dotnet/releases/tag/pyroscope-1.5.1",
	MinimumEffectiveCPUCores: 1, ThresholdOverrideAllowed: true,
	ThresholdOverrideMin: 0.1, ThresholdOverrideMax: 1,
	SupportedTypes: append([]string(nil), RequiredProfileTypes...),
}

var profilingHTTPClient = http.DefaultClient

func ValidateProfiling(p ProfilingPolicy) error {
	if strings.TrimSpace(p.StaticPhase) != "" {
		return fmt.Errorf("profile queries must not use a static perf_phase selector")
	}
	descriptor := p.Provider
	if descriptor.ID == "" {
		descriptor = DefaultProfilingProvider
	}
	if descriptor.ID == "" || descriptor.Version == "" || strings.TrimSpace(descriptor.Source) == "" || descriptor.MinimumEffectiveCPUCores <= 0 {
		return fmt.Errorf("profiling provider descriptor is incomplete")
	}
	if p.QuotaCores <= 0 || math.IsNaN(p.QuotaCores) || math.IsInf(p.QuotaCores, 0) {
		return fmt.Errorf("effective CPU quota must be positive and finite")
	}
	threshold := p.ThresholdCores
	if threshold == 0 {
		threshold = descriptor.MinimumEffectiveCPUCores
	}
	if threshold <= 0 || math.IsNaN(threshold) || math.IsInf(threshold, 0) {
		return fmt.Errorf("minimum-core threshold must be positive and finite")
	}
	if threshold != descriptor.MinimumEffectiveCPUCores {
		if !descriptor.ThresholdOverrideAllowed {
			return fmt.Errorf("%s %s does not permit a minimum-core threshold override", descriptor.ID, descriptor.Version)
		}
		if threshold < descriptor.ThresholdOverrideMin || threshold > descriptor.ThresholdOverrideMax {
			return fmt.Errorf("minimum-core threshold %.3g is outside %s %s supported range %.3g..%.3g", threshold, descriptor.ID, descriptor.Version, descriptor.ThresholdOverrideMin, descriptor.ThresholdOverrideMax)
		}
	}
	if p.QuotaCores < threshold {
		return fmt.Errorf("effective CPU quota %.3g is below %s %s threshold %.3g", p.QuotaCores, descriptor.ID, descriptor.Version, threshold)
	}
	if p.Unmanaged && !p.ReadOnlyVerify {
		return fmt.Errorf("unmanaged profiler config must be verified read-only")
	}
	if p.Unmanaged && (p.VerifiedAt.IsZero() || time.Since(p.VerifiedAt) > 15*time.Minute || p.VerifiedAt.After(time.Now().Add(time.Minute))) {
		return fmt.Errorf("unmanaged profiler verification is missing, stale, or future-dated")
	}
	if len(p.Types) == 0 {
		return fmt.Errorf("at least one profiling type is required")
	}
	seen := map[string]bool{}
	for _, profileType := range p.Types {
		if seen[profileType] || !slices.Contains(descriptor.SupportedTypes, profileType) {
			return fmt.Errorf("unsupported or duplicate profiling type %q", profileType)
		}
		seen[profileType] = true
	}
	return nil
}

func ValidateProfilingSettings(settings ProfilingSettings, types []string, expected map[string]string, unmanaged bool, verifiedAt time.Time) error {
	if len(settings.Services) == 0 {
		return fmt.Errorf("profiling descriptor has no services")
	}
	if !sameProfilingProvider(settings.Provider, DefaultProfilingProvider) {
		return fmt.Errorf("profiling provider descriptor does not match the pinned %s %s capability", DefaultProfilingProvider.ID, DefaultProfilingProvider.Version)
	}
	for role, serviceName := range expected {
		service, ok := settings.Services[role]
		if !ok {
			service, ok = settings.Services[serviceName]
		}
		if !ok {
			return fmt.Errorf("profiling descriptor is missing service %q", role)
		}
		if strings.TrimSpace(service.QuotaSource) == "" {
			return fmt.Errorf("profiling service %q is missing quotaSource", role)
		}
		if unmanaged {
			if strings.TrimSpace(service.ActivationProbe) != "active" {
				return fmt.Errorf("unmanaged profiling service %q activation probe is not active", role)
			}
			for _, requested := range types {
				if !slices.Contains(service.ActiveTypes, requested) {
					return fmt.Errorf("unmanaged profiling service %q has not verified requested type %q", role, requested)
				}
			}
		}
		if err := ValidateProfiling(ProfilingPolicy{
			Types: types, QuotaCores: service.EffectiveCPUCores,
			ThresholdCores: settings.ThresholdCores, Provider: settings.Provider,
			Unmanaged: unmanaged, ReadOnlyVerify: unmanaged, VerifiedAt: verifiedAt,
		}); err != nil {
			return fmt.Errorf("profiling service %q: %w", role, err)
		}
	}
	return nil
}

func sameProfilingProvider(left, right ProviderDescriptor) bool {
	if left.ID != right.ID || left.Version != right.Version || left.Source != right.Source ||
		left.MinimumEffectiveCPUCores != right.MinimumEffectiveCPUCores ||
		left.ThresholdOverrideAllowed != right.ThresholdOverrideAllowed ||
		left.ThresholdOverrideMin != right.ThresholdOverrideMin ||
		left.ThresholdOverrideMax != right.ThresholdOverrideMax || len(left.SupportedTypes) != len(right.SupportedTypes) {
		return false
	}
	for _, profileType := range left.SupportedTypes {
		if !slices.Contains(right.SupportedTypes, profileType) {
			return false
		}
	}
	return true
}

func ReadProfilingVerification(rawURL string) (ProfilingVerification, string, error) {
	rawURL = strings.TrimSpace(rawURL)
	parsed, err := url.Parse(rawURL)
	if rawURL == "" || err != nil || parsed.Hostname() == "" {
		return ProfilingVerification{}, "", fmt.Errorf("remote continuous profiling requires a valid read-only verification URL")
	}
	host := strings.ToLower(parsed.Hostname())
	loopback := host == "localhost" || host == "127.0.0.1" || host == "::1"
	if parsed.Scheme != "https" && !(parsed.Scheme == "http" && loopback) {
		return ProfilingVerification{}, "", fmt.Errorf("profiling verification URL must use HTTPS (HTTP is allowed only for loopback testing)")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return ProfilingVerification{}, "", fmt.Errorf("create profiling verification request: %w", err)
	}
	response, err := profilingHTTPClient.Do(request)
	if err != nil {
		return ProfilingVerification{}, "", fmt.Errorf("read profiling verification endpoint: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return ProfilingVerification{}, "", fmt.Errorf("profiling verification endpoint returned HTTP %d", response.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, (1<<20)+1))
	if err != nil {
		return ProfilingVerification{}, "", fmt.Errorf("read profiling verification response: %w", err)
	}
	if len(body) > 1<<20 {
		return ProfilingVerification{}, "", fmt.Errorf("profiling verification response exceeds 1048576 bytes")
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	var document ProfilingVerification
	if err := decoder.Decode(&document); err != nil {
		return ProfilingVerification{}, "", fmt.Errorf("decode profiling verification response: %w", err)
	}
	if decoder.Decode(&struct{}{}) != io.EOF {
		return ProfilingVerification{}, "", fmt.Errorf("profiling verification response contains trailing JSON")
	}
	digest := sha256.Sum256(body)
	return document, hex.EncodeToString(digest[:]), nil
}

func ProfilingSettingsDigest(settings ProfilingSettings) (string, error) {
	body, err := json.Marshal(settings)
	if err != nil {
		return "", fmt.Errorf("encode profiling settings: %w", err)
	}
	digest := sha256.Sum256(body)
	return hex.EncodeToString(digest[:]), nil
}

func ResolveProfilingTypes(policy, explicit string) ([]string, error) {
	if strings.TrimSpace(explicit) != "" {
		parts := strings.Split(explicit, ",")
		for i := range parts {
			parts[i] = strings.TrimSpace(parts[i])
		}
		if err := ValidateProfiling(ProfilingPolicy{Types: parts, QuotaCores: 1}); err != nil {
			return nil, err
		}
		return parts, nil
	}
	policy = strings.TrimSpace(policy)
	if policy == "" {
		policy = "cpu"
	}
	types, ok := profilingPolicies[policy]
	if !ok {
		return nil, fmt.Errorf("unknown profiling policy %q", policy)
	}
	return append([]string(nil), types...), nil
}

func ProfilingCaptureMap(present map[string]string) map[string]string {
	out := map[string]string{}
	for _, name := range RequiredProfileTypes {
		if state, ok := present[name]; ok {
			if slices.Contains(profilingCaptureStates, state) {
				out[name] = state
			} else {
				out[name] = "failed"
			}
			continue
		}
		out[name] = "missing"
	}
	return out
}
