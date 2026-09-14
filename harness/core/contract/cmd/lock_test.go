package main

import (
	"strings"
	"testing"
)

func TestTextOKRejectsBOMAndCRLF(t *testing.T) {
	if err := textOK([]byte("\xef\xbb\xbfhi\n")); err == nil {
		t.Fatal("expected BOM rejection")
	}
	if err := textOK([]byte("hi\r\n")); err == nil {
		t.Fatal("expected CRLF rejection")
	}
	if err := textOK([]byte("hi\n\n")); err == nil {
		t.Fatal("expected extra LF rejection")
	}
	if err := textOK([]byte("hi\n")); err != nil {
		t.Fatal(err)
	}
}

func TestAggregateDigestAlgorithm(t *testing.T) {
	// logical name, NUL, 64-char digest, LF; sorted by unsigned UTF-8 bytes.
	pre := []byte("a\x00" + strings.Repeat("a", 64) + "\n" + "b\x00" + strings.Repeat("b", 64) + "\n")
	if got := sha(pre); len(got) != 64 {
		t.Fatalf("digest length %d", len(got))
	}
	if sha([]byte("a")) == sha([]byte("b")) {
		t.Fatal("distinct preimages must not collide in this test")
	}
}
