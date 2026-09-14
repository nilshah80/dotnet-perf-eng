package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/nilshah80/dotnet-perf-eng/catalog"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "Usage:")
	fmt.Fprintln(os.Stderr, "  catalog validate-catalog <catalog.json>")
	fmt.Fprintln(os.Stderr, "  catalog migrate-catalog <scenarios.tsv> <out.json>")
	fmt.Fprintln(os.Stderr, "  catalog list <catalog.json>")
	fmt.Fprintln(os.Stderr, "  catalog lookup <catalog.json> <id> <field> [scenarios.tsv]")
}

func run(args []string) error {
	switch args[0] {
	case "validate-catalog", "validate":
		if len(args) != 2 {
			return fmt.Errorf("validate-catalog <catalog.json>")
		}
		doc, err := catalog.LoadFile(args[1])
		if err != nil {
			return err
		}
		fmt.Printf("ok %s revision=%s scenarios=%d\n", args[1], doc.ContractRevision, len(doc.Scenarios))
		return nil
	case "migrate-catalog", "migrate":
		if len(args) != 3 {
			return fmt.Errorf("migrate-catalog <scenarios.tsv> <out.json>")
		}
		_, raw, err := catalog.MigrateTSVFile(args[1])
		if err != nil {
			return err
		}
		if err := os.MkdirAll(filepath.Dir(args[2]), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(args[2], raw, 0o644); err != nil {
			return err
		}
		fmt.Printf("wrote %s\n", args[2])
		return nil
	case "list":
		if len(args) != 2 {
			return fmt.Errorf("list <catalog.json>")
		}
		doc, err := catalog.LoadFile(args[1])
		if err != nil {
			return err
		}
		fmt.Println(strings.Join(catalog.IDs(doc), "\n"))
		return nil
	case "lookup":
		if len(args) < 4 || len(args) > 5 {
			return fmt.Errorf("lookup <catalog.json> <id> <field> [scenarios.tsv]")
		}
		doc, err := catalog.LoadFile(args[1])
		if err != nil {
			return err
		}
		var rows []catalog.TSVRow
		if len(args) == 5 {
			rows, err = catalog.LoadTSV(args[4])
			if err != nil {
				return err
			}
		}
		value, err := catalog.LookupV1Field(doc, rows, args[2], args[3])
		if err != nil {
			return err
		}
		fmt.Print(value)
		return nil
	default:
		usage()
		return fmt.Errorf("unknown command %s", args[0])
	}
}
