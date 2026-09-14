package performance

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

func testProfilingSettings() ProfilingSettings {
	return ProfilingSettings{
		Provider:       DefaultProfilingProvider,
		ThresholdCores: 0.1,
		Services: map[string]ProfilingService{
			"api": {
				EffectiveCPUCores: 0.75, QuotaSource: "test-cgroup",
				ActiveTypes: append([]string(nil), RequiredProfileTypes...), ActivationProbe: "active",
			},
		},
	}
}

type profilingRoundTripFunc func(*http.Request) (*http.Response, error)

func (fn profilingRoundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return fn(request)
}

func TestProfilingSettingsValidateQuotaAndTypes(t *testing.T) {
	settings := testProfilingSettings()
	if err := ValidateProfilingSettings(settings, RequiredProfileTypes, map[string]string{"api": "checkout-api"}, false, time.Time{}); err != nil {
		t.Fatal(err)
	}
	settings.Services["api"] = ProfilingService{EffectiveCPUCores: 0.05, QuotaSource: "test-cgroup"}
	if err := ValidateProfilingSettings(settings, []string{"cpu"}, map[string]string{"api": "checkout-api"}, false, time.Time{}); err == nil {
		t.Fatal("quota below the versioned threshold was accepted")
	}
}

func TestReadProfilingVerificationIsFreshAndStrict(t *testing.T) {
	var body strings.Builder
	if err := json.NewEncoder(&body).Encode(ProfilingVerification{
		VerifiedAt: time.Now().UTC(), Profiling: testProfilingSettings(),
	}); err != nil {
		t.Fatal(err)
	}
	previous := profilingHTTPClient
	profilingHTTPClient = &http.Client{Transport: profilingRoundTripFunc(func(_ *http.Request) (*http.Response, error) {
		return &http.Response{
			StatusCode: http.StatusOK, Header: http.Header{"Content-Type": []string{"application/json"}},
			Body: io.NopCloser(strings.NewReader(body.String())),
		}, nil
	})}
	t.Cleanup(func() { profilingHTTPClient = previous })
	document, digest, err := ReadProfilingVerification("https://profiling-verification.test/config")
	if err != nil || len(digest) != 64 {
		t.Fatalf("verification read: digest=%q err=%v", digest, err)
	}
	if err := ValidateProfilingSettings(document.Profiling, []string{"cpu"}, map[string]string{"api": "checkout-api"}, true, document.VerifiedAt); err != nil {
		t.Fatal(err)
	}
	document.VerifiedAt = time.Now().Add(-16 * time.Minute)
	if err := ValidateProfilingSettings(document.Profiling, []string{"cpu"}, map[string]string{"api": "checkout-api"}, true, document.VerifiedAt); err == nil || !strings.Contains(err.Error(), "stale") {
		t.Fatalf("stale verification accepted: %v", err)
	}
}
