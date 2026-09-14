package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

func cmdNormalize(args []string) int {
	flags, err := parseFlags(args, false, true)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return exitUsage
	}
	m, err := loadManifest()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return exitUsage
	}
	scriptHash, err := normalizeScriptHash(flags)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return exitUsage
	}
	report, err := parseJTLFile(flags.JTL)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return exitExec
	}
	summary, err := summarize(report, scriptHash, m)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return exitExec
	}
	if err := publish(flags.OutputDir, flags.Phase, summary, flags.Phase == "" || flags.Phase == "measure"); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return exitPublish
	}
	return exitOK
}

func normalizeScriptHash(flags invocation) (string, error) {
	if strings.TrimSpace(flags.WorkloadRoot) == "" || strings.TrimSpace(flags.Plan) == "" {
		raw, err := os.ReadFile(flags.JTL)
		if err != nil {
			return "", err
		}
		return hashBytes(raw), nil
	}
	files, err := inventory(flags.Plan, flags.Files)
	if err != nil {
		return "", err
	}
	if err := ensureFiles(flags.WorkloadRoot, files); err != nil {
		return "", err
	}
	return hashFiles(flags.WorkloadRoot, files)
}

func cmdRunOnce(args []string) int {
	flags, err := parseFlags(args, true, false)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return exitUsage
	}
	m, err := loadManifest()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return exitUsage
	}
	files, err := inventory(flags.Plan, flags.Files)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return exitUsage
	}
	if err := ensureFiles(flags.WorkloadRoot, files); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return exitUsage
	}
	threads, err := strconv.Atoi(strings.TrimSpace(os.Getenv("PERFLAB_CONNECTIONS")))
	if err != nil || threads < 1 {
		fmt.Fprintln(os.Stderr, "PERFLAB_CONNECTIONS must be a positive integer")
		return exitUsage
	}
	if threads > m.MaxThreads {
		fmt.Fprintf(os.Stderr, "requested concurrency %d exceeds adapter maxThreads %d\n", threads, m.MaxThreads)
		return exitUsage
	}
	home := strings.TrimSpace(os.Getenv("JMETER_HOME"))
	if home == "" {
		fmt.Fprintln(os.Stderr, "JMETER_HOME is not set; refusing to launch JMeter")
		return exitUsage
	}
	scratch := filepath.Join(flags.OutputDir, ".scratch", flags.Phase)
	if err := os.MkdirAll(scratch, 0o750); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return exitPublish
	}
	jtlPath := filepath.Join(scratch, "results.jtl")
	bindings := RunProperties()
	argv, err := jmeterArgs(home, flags.WorkloadRoot, flags.Plan, scratch, jtlPath, javaPropertyMap(bindings))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return exitUsage
	}
	ctx, cancel := context.WithTimeout(context.Background(), flags.Timeout)
	defer cancel()
	if err := runJava(ctx, argv, flags.WorkloadRoot); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return exitExec
	}
	scriptHash, err := hashFiles(flags.WorkloadRoot, files)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return exitUsage
	}
	report, err := parseJTLFile(jtlPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return exitExec
	}
	summary, err := summarize(report, scriptHash, m)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return exitExec
	}
	writeObs := flags.Phase == "measure"
	if err := publish(flags.OutputDir, flags.Phase, summary, writeObs); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return exitPublish
	}
	if err := copyFile(jtlPath, filepath.Join(flags.OutputDir, "benchmark", jtlFile(flags.Phase))); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return exitPublish
	}
	if legacy := describeLegacy(bindings); len(legacy) > 0 {
		fmt.Fprintf(os.Stderr, "v1 property adapter applied: %s\n", strings.Join(legacy, ", "))
	}
	return exitOK
}

func ensureFiles(root string, files []string) error {
	for _, rel := range files {
		path := filepath.Join(root, filepath.FromSlash(rel))
		info, err := os.Stat(path)
		if err != nil {
			return fmt.Errorf("workload file %s: %w", rel, err)
		}
		if info.IsDir() {
			return fmt.Errorf("workload file %s is a directory", rel)
		}
	}
	return nil
}

func jmeterArgs(home, workloadRoot, plan, scratch, jtl string, properties map[string]string) ([]string, error) {
	jar := filepath.Join(home, "bin", "ApacheJMeter.jar")
	if _, err := os.Stat(jar); err != nil {
		return nil, fmt.Errorf("Apache JMeter jar not found under JMETER_HOME (%s)", jar)
	}
	java := "java"
	if javaHome := strings.TrimSpace(os.Getenv("JAVA_HOME")); javaHome != "" {
		candidate := filepath.Join(javaHome, "bin", "java")
		if _, err := os.Stat(candidate); err == nil {
			java = candidate
		}
	}
	logPath := filepath.Join(scratch, "jmeter.log")
	args := []string{
		java,
		"-Djava.awt.headless=true",
		"-Duser.home=" + filepath.Join(scratch, "home"),
		"-Djava.io.tmpdir=" + filepath.Join(scratch, "tmp"),
		"-jar", jar,
		"-n",
		"-t", filepath.Join(workloadRoot, filepath.FromSlash(plan)),
		"-l", jtl,
		"-j", logPath,
		"-Jjmeter.save.saveservice.output_format=csv",
		"-Jjmeter.save.saveservice.print_field_names=true",
		"-Jjmeter.save.saveservice.timestamp_format=ms",
		"-Jjmeter.save.saveservice.time=true",
		"-Jjmeter.save.saveservice.label=true",
		"-Jjmeter.save.saveservice.response_code=true",
		"-Jjmeter.save.saveservice.response_message=true",
		"-Jjmeter.save.saveservice.successful=true",
		"-Jjmeter.save.saveservice.latency=true",
	}
	names := make([]string, 0, len(properties))
	for name := range properties {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		args = append(args, "-J"+name+"="+properties[name])
	}
	if err := os.MkdirAll(filepath.Join(scratch, "home"), 0o750); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Join(scratch, "tmp"), 0o750); err != nil {
		return nil, err
	}
	return args, nil
}

func runJava(ctx context.Context, argv []string, workdir string) error {
	if len(argv) == 0 {
		return fmt.Errorf("empty JMeter command")
	}
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Dir = workdir
	cmd.Env = os.Environ()
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		if ctx.Err() != nil {
			return fmt.Errorf("JMeter timed out: %w", ctx.Err())
		}
		return fmt.Errorf("JMeter execution failed: %w", err)
	}
	return nil
}
