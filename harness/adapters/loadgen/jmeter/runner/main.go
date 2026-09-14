package main

import (
	"fmt"
	"os"
)

const (
	exitOK      = 0
	exitUsage   = 2
	exitExec    = 3
	exitPublish = 4
)

func main() {
	os.Exit(Main(os.Args[1:]))
}

// Main is the static helper entry used by tests and the container image.
func Main(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: dotnet-perf-eng-load-jmeter run-once | normalize | version [--json]")
		return exitUsage
	}
	switch args[0] {
	case "version":
		return cmdVersion(args[1:])
	case "normalize":
		return cmdNormalize(args[1:])
	case "run-once":
		return cmdRunOnce(args[1:])
	case "-h", "--help", "help":
		fmt.Fprintln(os.Stderr, "usage: dotnet-perf-eng-load-jmeter run-once | normalize | version [--json]")
		return exitOK
	default:
		fmt.Fprintf(os.Stderr, "unknown mode %q (want run-once, normalize, or version)\n", args[0])
		return exitUsage
	}
}
