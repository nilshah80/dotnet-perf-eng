package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/nilshah80/dotnet-perf-eng/capability"
	"github.com/nilshah80/dotnet-perf-eng/catalog"
	"github.com/nilshah80/dotnet-perf-eng/comparison"
	"github.com/nilshah80/dotnet-perf-eng/datafault"
	engine "github.com/nilshah80/dotnet-perf-eng/performance"
	"github.com/nilshah80/dotnet-perf-eng/profile"
	"github.com/nilshah80/dotnet-perf-eng/session"
	"github.com/nilshah80/dotnet-perf-eng/target"
	"github.com/nilshah80/dotnet-perf-eng/workload"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "Usage: performance <catalog|capability|profile|session|target|compare|partition|protocol|workload|profiling> ...")
		os.Exit(2)
	}
	if err := dispatch(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func dispatch(args []string) error {
	switch args[0] {
	case "catalog":
		return catalogCmd(args[1:])
	case "capability":
		return capabilityCmd(args[1:])
	case "profile":
		return profileCmd(args[1:])
	case "session":
		return sessionCmd(args[1:])
	case "target":
		return targetCmd(args[1:])
	case "compare":
		return compareCmd(args[1:])
	case "partition":
		return partitionCmd(args[1:])
	case "protocol":
		return protocolCmd(args[1:])
	case "workload":
		return workloadCmd(args[1:])
	case "profiling":
		return profilingCmd(args[1:])
	default:
		return fmt.Errorf("unknown engine %s", args[0])
	}
}

func catalogCmd(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("catalog validate-catalog|migrate-catalog ...")
	}
	switch args[0] {
	case "validate-catalog", "validate":
		if len(args) != 2 {
			return fmt.Errorf("catalog validate-catalog <file>")
		}
		doc, err := catalog.LoadFile(args[1])
		if err != nil {
			return err
		}
		fmt.Printf("ok revision=%s scenarios=%d\n", doc.ContractRevision, len(doc.Scenarios))
		return nil
	case "migrate-catalog", "migrate":
		if len(args) != 3 {
			return fmt.Errorf("catalog migrate-catalog <tsv> <out>")
		}
		_, raw, err := catalog.MigrateTSVFile(args[1])
		if err != nil {
			return err
		}
		return os.WriteFile(args[2], raw, 0o644)
	default:
		return fmt.Errorf("unknown catalog command %s", args[0])
	}
}

func capabilityCmd(args []string) error {
	if len(args) < 1 {
		return fmt.Errorf("capability advertise <generator> [workload]")
	}
	if args[0] != "advertise" {
		return fmt.Errorf("unknown capability command %s", args[0])
	}
	generator := "k6"
	workloadKind := "request"
	if len(args) > 1 {
		generator = args[1]
	}
	if len(args) > 2 {
		workloadKind = args[2]
	}
	if err := capability.RejectUnsupported(generator, workloadKind); err != nil {
		return err
	}
	ad, err := engine.AdvertiseOrReject("", generator, workloadKind)
	if err != nil {
		return err
	}
	raw, err := capability.Encode(ad)
	if err != nil {
		return err
	}
	os.Stdout.Write(raw)
	return nil
}

func profileCmd(args []string) error {
	if len(args) < 1 {
		return fmt.Errorf("profile <kind>|k6-config|duration")
	}
	switch args[0] {
	case "k6-config":
		if len(args) < 4 {
			return fmt.Errorf("profile k6-config <kind> <connections> <durationSeconds>")
		}
		connections := atoiDefault(args[2], 8)
		duration := atoiDefault(args[3], 30)
		in := profile.Input{
			Kind: args[1], Rate: float64(connections), DurationSeconds: duration,
			WorkloadType: firstNonEmpty(os.Getenv("PERF_WORKLOAD_KIND"), "request"),
			MaxRate:      float64(atoiDefault(os.Getenv("PERFLAB_MAX_VUS"), connections*4)),
			SpikeRate:    float64(atoiDefault(os.Getenv("PERFLAB_SPIKE_VUS"), connections*4)),
			SoakSeconds:  atoiDefault(os.Getenv("PERFLAB_SOAK_DURATION_SECONDS"), 0),
		}
		if in.Kind == "open" || in.Kind == "arrival" || in.Kind == "capacity" || in.Kind == "knee" {
			if rps := atoiDefault(os.Getenv("PERFLAB_TARGET_RPS"), connections*10); rps > 0 {
				in.Rate = float64(rps)
			}
		}
		compiled, err := profile.Compile(in)
		if err != nil {
			return err
		}
		raw, err := profile.K6Config(compiled, in, connections, atoiDefault(os.Getenv("PERFLAB_MAX_VUS"), connections*4))
		if err != nil {
			return err
		}
		os.Stdout.Write(raw)
		return nil
	case "duration":
		if len(args) < 4 {
			return fmt.Errorf("profile duration <kind> <connections> <durationSeconds>")
		}
		connections := atoiDefault(args[2], 8)
		duration := atoiDefault(args[3], 30)
		in := profile.Input{
			Kind: args[1], Rate: float64(connections), DurationSeconds: duration,
			WorkloadType: firstNonEmpty(os.Getenv("PERF_WORKLOAD_KIND"), "request"),
			MaxRate:      float64(atoiDefault(os.Getenv("PERFLAB_MAX_VUS"), connections*4)),
			SpikeRate:    float64(atoiDefault(os.Getenv("PERFLAB_SPIKE_VUS"), connections*4)),
			SoakSeconds:  atoiDefault(os.Getenv("PERFLAB_SOAK_DURATION_SECONDS"), 0),
		}
		compiled, err := profile.Compile(in)
		if err != nil {
			return err
		}
		fmt.Print(profile.DurationSeconds(compiled))
		return nil
	}
	compiled, err := profile.Compile(profile.Input{Kind: args[0], Rate: 8, DurationSeconds: 30, WorkloadType: firstNonEmpty(os.Getenv("PERF_WORKLOAD_KIND"), "request")})
	if err != nil {
		return err
	}
	raw, err := profile.Encode(compiled)
	if err != nil {
		return err
	}
	os.Stdout.Write(raw)
	return nil
}

func sessionCmd(args []string) error {
	kind := "probe"
	if len(args) > 0 {
		kind = args[0]
	}
	if kind == "adapter" {
		if len(args) < 2 {
			return fmt.Errorf("session adapter <k6|jmeter|wrk>")
		}
		switch args[1] {
		case "wrk":
			kind = "probe"
		case "k6", "jmeter":
			kind = "base"
		default:
			return fmt.Errorf("session adapter k6|jmeter|wrk")
		}
	}
	var sess *session.LoadSession
	switch kind {
	case "probe":
		sess = session.NewProbeOnly()
	case "base":
		sess = session.NewBaseSession()
	case "update":
		sess = session.NewUpdatingSession()
	default:
		return fmt.Errorf("session probe|base|update")
	}
	if err := session.RejectSoak(sess); err != nil {
		return err
	}
	fmt.Println("soak allowed")
	return nil
}

func targetCmd(args []string) error {
	if len(args) < 1 {
		return fmt.Errorf("target <kind> <ownership>|deploy-check <kind> <ownership>|start-check <kind> <ownership>")
	}
	action := "status"
	kind := args[0]
	ownership := target.OwnershipManaged
	if args[0] == "deploy-check" || args[0] == "start-check" {
		if len(args) < 3 {
			return fmt.Errorf("target %s <kind> <ownership>", args[0])
		}
		action = args[0]
		kind = args[1]
		ownership = target.Ownership(args[2])
	} else if len(args) >= 2 {
		ownership = target.Ownership(args[1])
	}
	d, err := target.New("cli", target.Kind(kind), ownership, target.WriteNone)
	if err != nil {
		return err
	}
	switch action {
	case "deploy-check":
		return d.CanDeploy()
	case "start-check":
		return d.CanStartStop()
	}
	if err := d.CanDeploy(); err != nil {
		fmt.Printf("deploy=denied %s\n", err)
		return nil
	}
	fmt.Println("deploy=allowed")
	return nil
}

func compareCmd(args []string) error {
	workloadType := "request"
	if len(args) > 0 {
		workloadType = args[0]
	}
	in := comparison.EligibilityInput{WorkloadType: workloadType, SourceDigest: strings.Repeat("a", 64)}
	if workloadType == "journey" {
		in.HasJourney = true
	}
	p := comparison.ProjectLegacyRequestV1(in)
	if err := comparison.Inconclusive(p); err != nil {
		return err
	}
	fmt.Println("eligible")
	return nil
}

func protocolCmd(args []string) error {
	kind := engine.ProtocolGRPC
	if len(args) > 0 {
		kind = engine.ProtocolKind(args[0])
	}
	return engine.ValidateProtocol(kind, false)
}

func workloadCmd(args []string) error {
	if len(args) != 1 {
		return fmt.Errorf("workload <manifest.json>")
	}
	_, err := workload.LoadFile(args[0])
	if err != nil {
		return err
	}
	fmt.Println("ok")
	return nil
}

func profilingCmd(args []string) error {
	unmanaged := os.Getenv("PERFLAB_TARGET") == "remote"
	types, err := engine.ResolveProfilingTypes(os.Getenv("PERFLAB_PROFILING_POLICY"), os.Getenv("PERFLAB_PROFILING_TYPES"))
	if err != nil {
		return err
	}
	expected, err := profilingRoleServices(os.Getenv("PERFLAB_PYROSCOPE_ROLE_SERVICES"), os.Getenv("PERFLAB_PYROSCOPE_SERVICES"))
	if err != nil {
		return err
	}
	if unmanaged {
		document, digest, err := engine.ReadProfilingVerification(os.Getenv("PERFLAB_PROFILING_VERIFICATION_URL"))
		if err != nil {
			return err
		}
		if err := engine.ValidateProfilingSettings(document.Profiling, types, expected, true, document.VerifiedAt); err != nil {
			return err
		}
		return json.NewEncoder(os.Stdout).Encode(map[string]any{
			"captureState": "captured", "verification": "read-only-endpoint",
			"descriptorDigest": digest, "verifiedAt": document.VerifiedAt,
			"profiling": document.Profiling,
		})
	}
	threshold, err := profilingFloat("PERFLAB_PROFILING_MIN_CORES_THRESHOLD")
	if err != nil {
		return err
	}
	quotas, err := profilingServiceQuotas(os.Getenv("PERFLAB_PROFILING_SERVICE_QUOTAS"))
	if err != nil {
		return err
	}
	services := make(map[string]engine.ProfilingService, len(quotas))
	quotaSource := strings.TrimSpace(os.Getenv("PERFLAB_PROFILING_QUOTA_SOURCE"))
	if quotaSource == "" {
		return fmt.Errorf("PERFLAB_PROFILING_QUOTA_SOURCE is required")
	}
	for role, quota := range quotas {
		services[role] = engine.ProfilingService{EffectiveCPUCores: quota, QuotaSource: quotaSource}
	}
	settings := engine.ProfilingSettings{
		Provider: engine.DefaultProfilingProvider, Services: services, ThresholdCores: threshold,
	}
	if err := engine.ValidateProfilingSettings(settings, types, expected, false, time.Time{}); err != nil {
		return err
	}
	digest, err := engine.ProfilingSettingsDigest(settings)
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]any{
		"captureState": "captured", "verification": "managed-descriptor",
		"descriptorDigest": digest, "profiling": settings,
	})
}

func profilingRoleServices(roleMappings, serviceNames string) (map[string]string, error) {
	result := map[string]string{}
	for _, item := range strings.Fields(roleMappings) {
		parts := strings.SplitN(item, ":", 2)
		if len(parts) != 2 || strings.TrimSpace(parts[0]) == "" || strings.TrimSpace(parts[1]) == "" {
			return nil, fmt.Errorf("invalid PERFLAB_PYROSCOPE_ROLE_SERVICES item %q", item)
		}
		result[parts[0]] = parts[1]
	}
	if len(result) == 0 {
		for _, service := range strings.Fields(serviceNames) {
			result[service] = service
		}
	}
	if len(result) == 0 {
		return nil, fmt.Errorf("profiling requires PERFLAB_PYROSCOPE_ROLE_SERVICES or PERFLAB_PYROSCOPE_SERVICES")
	}
	return result, nil
}

func profilingServiceQuotas(raw string) (map[string]float64, error) {
	result := map[string]float64{}
	for _, item := range strings.Fields(raw) {
		parts := strings.SplitN(item, ":", 2)
		if len(parts) != 2 || strings.TrimSpace(parts[0]) == "" {
			return nil, fmt.Errorf("invalid PERFLAB_PROFILING_SERVICE_QUOTAS item %q", item)
		}
		quota, err := strconv.ParseFloat(parts[1], 64)
		if err != nil {
			return nil, fmt.Errorf("invalid profiling quota %q: %w", item, err)
		}
		result[parts[0]] = quota
	}
	if len(result) == 0 {
		return nil, fmt.Errorf("PERFLAB_PROFILING_SERVICE_QUOTAS is required")
	}
	return result, nil
}

func profilingFloat(name string) (float64, error) {
	raw := strings.TrimSpace(os.Getenv(name))
	if raw == "" {
		return 0, fmt.Errorf("%s is required", name)
	}
	value, err := strconv.ParseFloat(raw, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid %s: %w", name, err)
	}
	return value, nil
}

func atoiDefault(raw string, fallback int) int {
	if strings.TrimSpace(raw) == "" {
		return fallback
	}
	var n int
	if _, err := fmt.Sscanf(strings.TrimSpace(raw), "%d", &n); err != nil {
		return fallback
	}
	return n
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func partitionCmd(args []string) error {
	if len(args) < 1 {
		return fmt.Errorf("partition seed-reset|gate [runId|incomplete]")
	}
	runID := "run-cli"
	if len(args) > 1 && args[1] != "incomplete" {
		runID = args[1]
	}
	p := datafault.NewProvider()
	if _, err := p.Seed(runID, 10, true); err != nil {
		return err
	}
	if err := p.Reset(runID); err != nil {
		return err
	}
	switch args[0] {
	case "gate":
		if len(args) > 1 && args[1] == "incomplete" {
			if err := p.Gate(runID); err == nil {
				return fmt.Errorf("incomplete cleanup must fail the gate")
			}
			fmt.Println("gate cannot pass: cleanup incomplete")
			return fmt.Errorf("incomplete cleanup cannot pass a gate")
		}
		if err := p.Cleanup(runID); err != nil {
			return err
		}
		if err := p.Gate(runID); err != nil {
			return err
		}
		fmt.Println("gate pass: cleanup complete")
		return nil
	case "seed-reset":
		if _, err := p.Ready(runID); err != nil {
			return err
		}
		if err := workload.RequirePartitionForWrites("create", workload.PartitionState{
			RunID: runID, Seeded: true, ResetOK: true, Acknowledged: true, Budget: 10,
		}); err != nil {
			return err
		}
		fmt.Printf("partition %s ready for create/pay\n", runID)
		return nil
	default:
		return fmt.Errorf("partition seed-reset|gate")
	}
}
