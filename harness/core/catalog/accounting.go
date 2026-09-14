package catalog

import (
	"encoding/json"
	"fmt"
	"os"
)

type iterationFixture struct {
	ID    string          `json:"id"`
	Cases []iterationCase `json:"cases"`
}

type iterationCase struct {
	Name                    string   `json:"name"`
	MeasuredIterations      int      `json:"measuredIterations"`
	PrimaryProtocolRequests int      `json:"primaryProtocolRequests"`
	ExpectedOperationIDFrom string   `json:"expectedOperationIdFrom"`
	HTTPFailed              int      `json:"httpFailed"`
	TransportFailed         int      `json:"transportFailed"`
	RequestAttemptTotal     int      `json:"requestAttemptTotal"`
	Redirects               int      `json:"redirects"`
	NotCountedAsIteration   []string `json:"notCountedAsIteration"`
}

func LoadIterationFixture(path string) error {
	raw, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var fixture iterationFixture
	if err := json.Unmarshal(raw, &fixture); err != nil {
		return err
	}
	return CheckIterationFixture(fixture)
}

func CheckIterationFixture(fixture iterationFixture) error {
	if fixture.ID != "legacy-request-iteration-accounting" {
		return fmt.Errorf("unexpected iteration fixture id %q", fixture.ID)
	}
	for _, c := range fixture.Cases {
		if err := checkIterationCase(c); err != nil {
			return fmt.Errorf("%s: %w", c.Name, err)
		}
	}
	return nil
}

func checkIterationCase(c iterationCase) error {
	switch c.Name {
	case "one-primary-request":
		if c.MeasuredIterations != 1 || c.PrimaryProtocolRequests != 1 {
			return fmt.Errorf("one measured iteration must attempt exactly one primary request")
		}
		if c.ExpectedOperationIDFrom != "scenario-id" {
			return fmt.Errorf("stable operation id must be the scenario id")
		}
	case "failed-http-counts":
		if c.RequestAttemptTotal != c.HTTPFailed+c.TransportFailed {
			return fmt.Errorf("failed HTTP and transport attempts must be included in request-attempt totals")
		}
	case "redirects-separate":
		if c.Redirects < 1 {
			return fmt.Errorf("redirects must be counted separately")
		}
		if c.PrimaryProtocolRequests != 1 {
			return fmt.Errorf("redirects are not extra measured iterations")
		}
		for _, name := range c.NotCountedAsIteration {
			if name != "setup" && name != "teardown" && name != "authentication-bootstrap" {
				return fmt.Errorf("unexpected non-iteration name %q", name)
			}
		}
	default:
		return fmt.Errorf("unrecognized iteration case")
	}
	return nil
}
