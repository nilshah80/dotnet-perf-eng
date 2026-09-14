package target

import "testing"

func TestOwnershipGatesStartStop(t *testing.T) {
	compose, err := New("store", KindCompose, OwnershipManaged, WriteNone)
	if err != nil {
		t.Fatal(err)
	}
	if err := compose.CanStartStop(); err != nil {
		t.Fatal(err)
	}
	proc, err := New("api", KindLocalProcess, OwnershipNone, WriteNone)
	if err != nil {
		t.Fatal(err)
	}
	if err := proc.CanStartStop(); err == nil {
		t.Fatal("local-process must not start/stop")
	}
	if err := proc.CanDeploy(); err == nil {
		t.Fatal("unmanaged must never deploy")
	}
}

func TestRemoteAndExistingK8s(t *testing.T) {
	remote, err := New("prod", KindRemote, OwnershipNone, WriteNone)
	if err != nil {
		t.Fatal(err)
	}
	if err := remote.CanDeploy(); err == nil {
		t.Fatal("remote must not deploy")
	}
	existing, err := New("prod", KindExistingEnvironment, OwnershipNone, WriteNone)
	if err != nil {
		t.Fatal(err)
	}
	if err := existing.CanDeploy(); err == nil {
		t.Fatal("existing-environment must not deploy")
	}
	k8s, err := New("ns", KindExistingK8s, OwnershipNone, WriteNone)
	if err != nil {
		t.Fatal(err)
	}
	if err := k8s.CanMutateCluster(); err == nil {
		t.Fatal("existing-k8s must not apply/delete/scale")
	}
	kube, err := New("ns", KindExistingKubernetes, OwnershipNone, WriteNone)
	if err != nil {
		t.Fatal(err)
	}
	if err := kube.CanMutateCluster(); err == nil {
		t.Fatal("existing-kubernetes must not apply/delete/scale")
	}
}

func TestFieldsRemainSeparate(t *testing.T) {
	d, err := New("ref", KindCompose, OwnershipManaged, WriteManagedReference)
	if err != nil {
		t.Fatal(err)
	}
	if string(d.Lifecycle) == string(d.WriteClass) {
		t.Fatal("ownership and write-safety must not share a value space")
	}
}
