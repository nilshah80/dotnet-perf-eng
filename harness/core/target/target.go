package target

import "fmt"

type Kind string

const (
	KindLocalProcess        Kind = "local-process"
	KindLocalContainer      Kind = "local-container"
	KindCompose             Kind = "compose"
	KindManagedCompose      Kind = "managed-compose"
	KindRemote              Kind = "remote"
	KindExistingEnvironment Kind = "existing-environment"
	KindExistingK8s         Kind = "existing-k8s"
	KindExistingKubernetes  Kind = "existing-kubernetes"
	KindManagedKubernetes   Kind = "managed-kubernetes"
	KindAgent               Kind = "agent"
)

type Ownership string

const (
	OwnershipNone      Ownership = "none"
	OwnershipManaged   Ownership = "managed"
	OwnershipDelegated Ownership = "delegated"
)

type WriteSafety string

const (
	WriteNone             WriteSafety = "none"
	WriteManagedReference WriteSafety = "managed-reference"
)

type Descriptor struct {
	ID         string      `json:"id"`
	Kind       Kind        `json:"kind"`
	Lifecycle  Ownership   `json:"lifecycleOwnership"`
	WriteClass WriteSafety `json:"writeSafetyClass"`
	BaseURL    string      `json:"baseUrl,omitempty"`
}

func DefaultOwnership(kind Kind) Ownership {
	switch kind {
	case KindCompose, KindManagedCompose, KindManagedKubernetes, KindLocalContainer:
		return OwnershipManaged
	default:
		return OwnershipNone
	}
}

func New(id string, kind Kind, ownership Ownership, write WriteSafety) (Descriptor, error) {
	if ownership == "" {
		ownership = DefaultOwnership(kind)
	}
	if write == "" {
		write = WriteNone
	}
	switch kind {
	case KindLocalProcess, KindLocalContainer, KindCompose, KindManagedCompose, KindRemote, KindExistingEnvironment, KindExistingK8s, KindExistingKubernetes, KindManagedKubernetes, KindAgent:
	default:
		return Descriptor{}, fmt.Errorf("unknown target kind %q", kind)
	}
	switch ownership {
	case OwnershipNone, OwnershipManaged, OwnershipDelegated:
	default:
		return Descriptor{}, fmt.Errorf("unknown lifecycle.ownership %q", ownership)
	}
	switch write {
	case WriteNone, WriteManagedReference:
	default:
		return Descriptor{}, fmt.Errorf("unknown writeSafety.class %q", write)
	}
	return Descriptor{ID: id, Kind: kind, Lifecycle: ownership, WriteClass: write}, nil
}

func (d Descriptor) Unmanaged() bool {
	return d.Lifecycle == OwnershipNone
}

func (d Descriptor) CanStartStop() error {
	if d.Lifecycle != OwnershipManaged {
		return fmt.Errorf("lifecycle.ownership %s cannot start or stop target %s", d.Lifecycle, d.ID)
	}
	return nil
}

func (d Descriptor) CanDeploy() error {
	if d.Unmanaged() {
		return fmt.Errorf("unmanaged target %s must never deploy", d.ID)
	}
	switch d.Kind {
	case KindLocalProcess, KindRemote, KindExistingEnvironment, KindExistingK8s, KindExistingKubernetes, KindAgent:
		return fmt.Errorf("target kind %s must not deploy", d.Kind)
	}
	return d.CanStartStop()
}

func (d Descriptor) CanMutateCluster() error {
	if d.Kind == KindExistingK8s || d.Kind == KindExistingKubernetes {
		return fmt.Errorf("existing-k8s target %s performs no apply/delete/scale", d.ID)
	}
	if d.Unmanaged() {
		return fmt.Errorf("unmanaged target %s must not mutate infrastructure", d.ID)
	}
	return nil
}
