package proto

import (
	"bufio"
	"bytes"
	"testing"
)

func TestWriteReadRoundTrip(t *testing.T) {
	want := &Packet{Opcode: 0x3001, Data: []byte("hello")}

	var buf bytes.Buffer
	if err := Write(&buf, want); err != nil {
		t.Fatalf("Write: %v", err)
	}

	got, err := Read(bufio.NewReader(&buf))
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if got.Opcode != want.Opcode || !bytes.Equal(got.Data, want.Data) {
		t.Fatalf("round trip mismatch: got %+v, want %+v", got, want)
	}
}

func TestReadEmptyPayload(t *testing.T) {
	var buf bytes.Buffer
	if err := Write(&buf, &Packet{Opcode: 0x1000}); err != nil {
		t.Fatalf("Write: %v", err)
	}

	got, err := Read(bufio.NewReader(&buf))
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if got.Opcode != 0x1000 || len(got.Data) != 0 {
		t.Fatalf("unexpected packet: %+v", got)
	}
}

func TestReadRejectsEncryptedFlag(t *testing.T) {
	// Hand-build a frame with the encrypted bit set.
	frame := []byte{0x00, 0x00, 0x01, 0x30, secEncrypted}
	_, err := Read(bufio.NewReader(bytes.NewReader(frame)))
	if err != ErrEncrypted {
		t.Fatalf("expected ErrEncrypted, got %v", err)
	}
}

func TestReadRejectsMassiveFlag(t *testing.T) {
	frame := []byte{0x00, 0x00, 0x01, 0x30, secMassive}
	_, err := Read(bufio.NewReader(bytes.NewReader(frame)))
	if err != ErrMassivePacket {
		t.Fatalf("expected ErrMassivePacket, got %v", err)
	}
}

func TestWriteRejectsOversizedPayload(t *testing.T) {
	p := &Packet{Opcode: 1, Data: make([]byte, 0x10000)}
	if err := Write(&bytes.Buffer{}, p); err == nil {
		t.Fatal("expected error for oversized payload, got nil")
	}
}
