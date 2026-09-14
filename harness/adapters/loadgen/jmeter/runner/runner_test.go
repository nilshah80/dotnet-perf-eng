package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestShippedManifestsAgree(t *testing.T) {
	root := findRepoRoot(t)
	parent, err := os.ReadFile(filepath.Join(root, "harness/adapters/loadgen/jmeter/adapter-manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	embedded, err := os.ReadFile("adapter-manifest.json")
	if err != nil {
		t.Fatal(err)
	}
	if string(parent) != string(embedded) {
		t.Fatal("adapter-manifest.json copies diverged")
	}
	var m Manifest
	if err := json.Unmarshal(parent, &m); err != nil {
		t.Fatal(err)
	}
	if err := m.validate(); err != nil {
		t.Fatal(err)
	}
	if m.AdapterID != "dotnet-perf-eng.load.jmeter" {
		t.Fatalf("adapterId %q", m.AdapterID)
	}
}

func TestVersionJSONMatchesWireShape(t *testing.T) {
	t.Setenv("PERFLAB_PLUGIN_IMAGE_DIGEST", "sha256:"+strings.Repeat("ab", 32))
	t.Setenv("ADAPTER_MANIFEST", "")
	stdout, stderr, code := runMain(t, "version", "--json")
	if code != 0 {
		t.Fatalf("exit %d stderr=%s", code, stderr)
	}
	var doc VersionDocument
	if err := json.Unmarshal([]byte(stdout), &doc); err != nil {
		t.Fatal(err)
	}
	if err := ValidateVersionDocument(doc); err != nil {
		t.Fatal(err)
	}
	if doc.Generator != "jmeter" {
		t.Fatalf("generator %q", doc.Generator)
	}
	if doc.AdapterID != "dotnet-perf-eng.load.jmeter" {
		t.Fatalf("adapterId %q", doc.AdapterID)
	}
	if doc.AdapterVersion == "" {
		t.Fatal("adapterVersion empty")
	}
	if doc.ImageDigest != os.Getenv("PERFLAB_PLUGIN_IMAGE_DIGEST") {
		t.Fatalf("imageDigest %q", doc.ImageDigest)
	}
	if doc.CapabilityRevision != "v1" {
		t.Fatalf("capabilityRevision %q", doc.CapabilityRevision)
	}
	if !hex64.MatchString(doc.ContractDigest) {
		t.Fatalf("contractDigest %q", doc.ContractDigest)
	}
	if !strings.HasPrefix(doc.Fingerprint, "adapter=") {
		t.Fatalf("fingerprint %q", doc.Fingerprint)
	}
}

func TestMaxThreadsComesFromManifest(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "adapter-manifest.json")
	body := `{
  "adapterId": "dotnet-perf-eng.load.jmeter",
  "adapterVersion": "9.9.9",
  "cpus": 2,
  "memoryBytes": 2147483648,
  "maxThreads": 128,
  "capabilityRevision": "v1",
  "contractDigest": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
`
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ADAPTER_MANIFEST", path)
	stdout, stderr, code := runMain(t, "version", "--json")
	if code != 0 {
		t.Fatalf("exit %d stderr=%s", code, stderr)
	}
	var doc VersionDocument
	if err := json.Unmarshal([]byte(stdout), &doc); err != nil {
		t.Fatal(err)
	}
	if doc.MaxThreads != 128 {
		t.Fatalf("maxThreads %d, want 128 from manifest", doc.MaxThreads)
	}
	if doc.AdapterVersion != "9.9.9" {
		t.Fatalf("adapterVersion %q", doc.AdapterVersion)
	}
	if !strings.Contains(doc.Fingerprint, "maxThreads=128") {
		t.Fatalf("fingerprint %q", doc.Fingerprint)
	}
}

func TestMalformedVersionRejected(t *testing.T) {
	root := findRepoRoot(t)
	raw, err := os.ReadFile(filepath.Join(root, "contracts/v1/fixtures/jmeter-adapter-wire/version-malformed.json"))
	if err != nil {
		t.Fatal(err)
	}
	_, err = decodeAndValidateVersionJSON(raw)
	if err == nil {
		t.Fatal("expected malformed version rejection")
	}
}

func TestPropertyAdapterMapsLegacyKeys(t *testing.T) {
	canonical, legacy := AdaptPropertyName("perflab.threads")
	if !legacy || canonical != "perf.threads" {
		t.Fatalf("got %s legacy=%v", canonical, legacy)
	}
	canonical, legacy = AdaptPropertyName("perf.base_url")
	if legacy || canonical != "perf.base_url" {
		t.Fatalf("got %s legacy=%v", canonical, legacy)
	}
	t.Setenv("PERFLAB_JMETER_PROP_THREADS", "perflab.threads")
	t.Setenv("PERFLAB_CONNECTIONS", "4")
	t.Setenv("PERFLAB_JMETER_PROP_BASE_URL", "")
	t.Setenv("PERF_BASE_URL", "http://api:8080")
	t.Setenv("PERFLAB_JMETER_PROP_DURATION_SECONDS", "")
	t.Setenv("PERFLAB_DURATION_SECONDS", "10")
	bindings := RunProperties()
	props := javaPropertyMap(bindings)
	if props["perf.threads"] != "4" {
		t.Fatalf("canonical threads missing: %v", props)
	}
	if props["perflab.threads"] != "4" {
		t.Fatalf("legacy threads missing: %v", props)
	}
	if props["perf.base_url"] != "http://api:8080" {
		t.Fatalf("canonical base url missing: %v", props)
	}
	if _, ok := props["perflab.base_url"]; ok {
		t.Fatalf("default must not emit perflab.base_url: %v", props)
	}
	if got := describeLegacy(bindings); len(got) == 0 {
		t.Fatal("expected recorded v1 adapter use")
	}
}

func TestJourneyParentChildAreNotDoubleCounted(t *testing.T) {
	raw := "timeStamp,elapsed,label,responseCode,responseMessage,success,Latency\n" +
		"1700000000000,160,journey::checkout,200,\"Number of samples in transaction : 5, number of failing samples : 0\",true,160\n" +
		"1700000000000,20,op::login,200,OK,true,20\n" +
		"1700000000020,30,op::browse,200,OK,true,30\n" +
		"1700000000050,20,op::pay,200,OK,true,20\n" +
		"1700000000070,30,op::poll,200,OK,true,30\n" +
		"1700000000100,30,op::poll,200,OK,true,30\n"
	report, err := parseJTL(strings.NewReader(raw))
	if err != nil {
		t.Fatal(err)
	}
	if report.JourneyIterations != 1 || len(report.RequestSamples) != 5 {
		t.Fatalf("parent/child split: iterations=%d requestSamples=%d samples=%d", report.JourneyIterations, len(report.RequestSamples), len(report.Samples))
	}
	summary, err := summarize(report, strings.Repeat("a", 64), Manifest{})
	if err != nil {
		t.Fatal(err)
	}
	if summary.Requests != 5 || summary.Iterations != 1 || summary.JourneyChildOps != 4 || summary.JourneyRetries != 1 {
		t.Fatalf("requests=%d iterations=%d", summary.Requests, summary.Iterations)
	}
	foundJourney := false
	for _, obs := range summary.observations() {
		if obs["name"] == "journeys.started" {
			foundJourney = true
		}
	}
	if !foundJourney {
		t.Fatal("journey observations missing")
	}
}

func TestInterruptedJourneyParentIsAborted(t *testing.T) {
	raw := "timeStamp,elapsed,label,responseCode,responseMessage,success,Latency\n" +
		"1700000000000,80,journey::checkout,200,,true,80\n" +
		"1700000000000,20,op::login,200,OK,true,20\n"
	report, err := parseJTL(strings.NewReader(raw))
	if err != nil {
		t.Fatal(err)
	}
	if report.JourneyIterations != 1 || report.JourneySucceeded != 0 || report.JourneyAborted != 1 {
		t.Fatalf("interrupted parent was not classified as aborted: %+v", report)
	}
}

func TestReferenceJourneyContainsRequiredSemantics(t *testing.T) {
	root := findRepoRoot(t)
	raw, err := os.ReadFile(filepath.Join(root, "labs/ecommerce/loadgen/checkout-journey.jmx"))
	if err != nil {
		t.Fatal(err)
	}
	text := string(raw)
	for _, required := range []string{
		`testname="require-http-success"`,
		`name="TransactionController.includeTimers">true`,
		`testname="journey-think-time"`,
		`testname="poll-until-complete"`,
		`testname="require-token"`,
		`testname="require-product"`,
		`testname="require-order"`,
		`${__threadNum}-${__iteration}-${perf.orderId}`,
	} {
		if !strings.Contains(text, required) {
			t.Fatalf("reference journey JMX missing %s", required)
		}
	}
}

func TestNormalizeTinyJTL(t *testing.T) {
	out := t.TempDir()
	jtl := filepath.Join("testdata", "tiny.jtl")
	_, stderr, code := runMain(t, "normalize", "--jtl", jtl, "--output-dir", out)
	if code != 0 {
		t.Fatalf("exit %d stderr=%s", code, stderr)
	}
	raw, err := os.ReadFile(filepath.Join(out, "benchmark", "observations.json"))
	if err != nil {
		t.Fatal(err)
	}
	var obs []map[string]any
	if err := json.Unmarshal(raw, &obs); err != nil {
		t.Fatal(err)
	}
	names := map[string]bool{}
	for _, row := range obs {
		name, _ := row["name"].(string)
		names[name] = true
	}
	for _, required := range []string{"http.latency.p50", "http.latency.p90", "http.latency.p95", "http.latency.p99", "http.requests.total"} {
		if !names[required] {
			t.Fatalf("missing observation %s in %s", required, raw)
		}
	}
	sumRaw, err := os.ReadFile(filepath.Join(out, "benchmark", "jmeter-summary-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var summary Summary
	if err := json.Unmarshal(sumRaw, &summary); err != nil {
		t.Fatal(err)
	}
	if summary.Requests != 4 || summary.ScriptHash == "" {
		t.Fatalf("summary %+v", summary)
	}
	if summary.StatusErrors != 1 {
		t.Fatalf("statusErrors %d", summary.StatusErrors)
	}
}

func TestRunOnceFailsClosedWithoutJMeterHome(t *testing.T) {
	t.Setenv("JMETER_HOME", "")
	t.Setenv("PERFLAB_CONNECTIONS", "1")
	out := t.TempDir()
	_, stderr, code := runMain(t,
		"run-once",
		"--phase", "measure",
		"--output-dir", out,
		"--timeout", "5s",
		"--workload-root", "testdata",
		"--plan", "plan.jmx",
	)
	if code == 0 {
		t.Fatal("expected fail-closed run-once")
	}
	if !strings.Contains(stderr, "JMETER_HOME") {
		t.Fatalf("stderr=%s", stderr)
	}
}

func TestRunOnceRejectsConcurrencyAboveMaxThreads(t *testing.T) {
	t.Setenv("JMETER_HOME", "")
	t.Setenv("PERFLAB_CONNECTIONS", "99999")
	out := t.TempDir()
	_, stderr, code := runMain(t,
		"run-once",
		"--phase", "measure",
		"--output-dir", out,
		"--timeout", "5s",
		"--workload-root", "testdata",
		"--plan", "plan.jmx",
	)
	if code == 0 {
		t.Fatal("expected maxThreads rejection")
	}
	if !strings.Contains(stderr, "maxThreads") {
		t.Fatalf("stderr=%s", stderr)
	}
}

func TestRunOnceFlagValidation(t *testing.T) {
	out := t.TempDir()
	_, stderr, code := runMain(t, "run-once", "--phase", "not-a-phase", "--output-dir", out, "--timeout", "5s", "--workload-root", "testdata", "--plan", "plan.jmx")
	if code == 0 || !strings.Contains(stderr, "--phase") {
		t.Fatalf("code=%d stderr=%s", code, stderr)
	}
	_, stderr, code = runMain(t, "run-once", "--phase", "measure", "--output-dir", out)
	if code == 0 || !strings.Contains(stderr, "--timeout") && !strings.Contains(stderr, "--workload-root") {
		t.Fatalf("code=%d stderr=%s", code, stderr)
	}
}

func runMain(t *testing.T, args ...string) (string, string, int) {
	t.Helper()
	stdout, stderr := os.Stdout, os.Stderr
	outR, outW, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	errR, errW, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stdout, os.Stderr = outW, errW
	code := Main(args)
	_ = outW.Close()
	_ = errW.Close()
	os.Stdout, os.Stderr = stdout, stderr
	var outBuf, errBuf bytes.Buffer
	_, _ = outBuf.ReadFrom(outR)
	_, _ = errBuf.ReadFrom(errR)
	return outBuf.String(), errBuf.String(), code
}

func findRepoRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 8; i++ {
		if _, err := os.Stat(filepath.Join(dir, "contracts", "contract-lock.json")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	t.Fatal("repository root not found")
	return ""
}
