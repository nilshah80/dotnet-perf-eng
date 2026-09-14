package comparison

import (
	"encoding/json"
	"fmt"
)

const ProjectionLegacyRequestV1 = "legacy-request-v1"

type Projection struct {
	ProjectionVersion     string   `json:"projectionVersion"`
	Eligible              bool     `json:"eligible"`
	SourceCandidateDigest string   `json:"sourceCandidateDigest"`
	ProjectedDigest       string   `json:"projectedDigest"`
	OmittedFields         []string `json:"omittedFields"`
	EligibilityChecks     []string `json:"eligibilityChecks"`
	BaselineApprovalID    string   `json:"baselineApprovalId,omitempty"`
}

type EligibilityInput struct {
	WorkloadType        string
	HasJourney          bool
	HasMix              bool
	HasProtocol         bool
	Distributed         bool
	ContinuousProfiling bool
	DiagnosticCampaign  bool
	Faults              bool
	Scaling             bool
	SourceDigest        string
	ProjectedDigest     string
	BaselineApprovalID  string
}

func ProjectLegacyRequestV1(in EligibilityInput) Projection {
	lossy := in.WorkloadType != "request" || in.HasJourney || in.HasMix || in.HasProtocol ||
		in.Distributed || in.ContinuousProfiling || in.DiagnosticCampaign || in.Faults || in.Scaling
	if !lossy {
		return Projection{
			ProjectionVersion:     ProjectionLegacyRequestV1,
			Eligible:              true,
			SourceCandidateDigest: in.SourceDigest,
			ProjectedDigest:       in.ProjectedDigest,
			OmittedFields:         []string{},
			EligibilityChecks:     []string{"legacy-request", "single-operation", "not-journey", "not-mix"},
			BaselineApprovalID:    in.BaselineApprovalID,
		}
	}
	omitted := []string{}
	checks := []string{}
	if in.HasJourney {
		omitted = append(omitted, "journeys")
		checks = append(checks, "journey-unrepresentable")
	}
	if in.HasMix {
		checks = append(checks, "mix-unrepresentable")
	}
	if in.HasProtocol {
		checks = append(checks, "protocol-unrepresentable")
	}
	if in.WorkloadType != "request" && !in.HasJourney && !in.HasMix {
		checks = append(checks, "not-legacy-request")
	}
	if in.Distributed {
		checks = append(checks, "distributed-unrepresentable")
	}
	if in.ContinuousProfiling {
		checks = append(checks, "continuous-profiling-unrepresentable")
	}
	if in.DiagnosticCampaign {
		checks = append(checks, "diagnostic-campaign-unrepresentable")
	}
	if in.Faults {
		checks = append(checks, "faults-unrepresentable")
	}
	if in.Scaling {
		checks = append(checks, "scaling-unrepresentable")
	}
	return Projection{
		ProjectionVersion:     ProjectionLegacyRequestV1,
		Eligible:              false,
		SourceCandidateDigest: in.SourceDigest,
		ProjectedDigest:       "",
		OmittedFields:         omitted,
		EligibilityChecks:     checks,
	}
}

func Inconclusive(p Projection) error {
	if p.Eligible {
		return nil
	}
	return fmt.Errorf("legacy-request-v1 projection ineligible; comparison is inconclusive")
}

func Decode(raw []byte) (Projection, error) {
	var p Projection
	if err := json.Unmarshal(raw, &p); err != nil {
		return Projection{}, err
	}
	return p, nil
}
