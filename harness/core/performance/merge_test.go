package performance

import "testing"

func TestShardPlanDoesNotMultiplyLoad(t *testing.T) {
	shards, err := PlanShards(4, 100)
	if err != nil {
		t.Fatal(err)
	}
	sum := 0.0
	for _, shard := range shards {
		sum += shard.Load
	}
	if sum != 100 {
		t.Fatalf("sum=%v", sum)
	}
	if err := JMeterShardSafe(100, 100); err != nil {
		t.Fatal(err)
	}
	if err := JMeterShardSafe(400, 100); err == nil {
		t.Fatal("expected multiplied load")
	}
}

func TestMergeNeverAveragesPercentiles(t *testing.T) {
	got := RejectPercentileAverage([]float64{10, 40, 25})
	if got != 40 {
		t.Fatalf("got %v", got)
	}
	agg, err := Merge([]Aggregate{
		{Requests: 10, Histogram: []int{1, 2, 7}},
		{Requests: 5, Histogram: []int{0, 1, 4}},
	})
	if err != nil || agg.Requests != 15 {
		t.Fatalf("%+v %v", agg, err)
	}
	if agg.Percentile["p95"] != 2 {
		t.Fatalf("merged p95=%v want histogram recompute not max-of-shards", agg.Percentile["p95"])
	}
	if _, err := Merge([]Aggregate{
		{Histogram: []int{1, 2}},
		{Histogram: []int{1, 2, 3}},
	}); err == nil {
		t.Fatal("shape mismatch must fail closed")
	}
}

func TestBrowserSyntheticIsSeparate(t *testing.T) {
	if !ProtocolRunsBesideBackend(ProtocolBrowser) {
		t.Fatal("browser-synthetic must not replace backend load")
	}
	if err := ValidateProtocol(ProtocolGRPC, false); err == nil {
		t.Fatal("unimplemented protocol must fail")
	}
}

func TestProfilingRejectsStaticPhase(t *testing.T) {
	if err := ValidateProfiling(ProfilingPolicy{QuotaCores: 1, StaticPhase: "perf"}); err == nil {
		t.Fatal("static phase must fail")
	}
	got := ProfilingCaptureMap(map[string]string{"cpu": "captured"})
	if got["wall"] != "missing" || got["cpu"] != "captured" {
		t.Fatal(got)
	}
}

func TestProfilingPoliciesCoverEveryDotNetType(t *testing.T) {
	types, err := ResolveProfilingTypes("all-diagnostic", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(types) != len(RequiredProfileTypes) {
		t.Fatalf("all-diagnostic types = %v", types)
	}
	if _, err := ResolveProfilingTypes("cpu", "cpu,unknown"); err == nil {
		t.Fatal("unknown explicit profile type was accepted")
	}
	states := ProfilingCaptureMap(map[string]string{"cpu": "partial"})
	if states["cpu"] != "failed" {
		t.Fatalf("invalid capture state was preserved: %v", states)
	}
}
