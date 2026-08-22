package proto

import (
	"bufio"
	"bytes"
	"testing"
)

func TestWriteReadRoundTrip(t *testing.T) {
	want := &Packet{Opcode: 0x3001, Data: []byte("hello")}

	var buf bytes.Buffer
	if err := Write(&buf, want, nil, nil); err != nil {
		t.Fatalf("Write: %v", err)
	}

	got, err := Read(bufio.NewReader(&buf), nil, nil)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if got.Opcode != want.Opcode || !bytes.Equal(got.Data, want.Data) {
		t.Fatalf("round trip mismatch: got %+v, want %+v", got, want)
	}
}

func TestReadEmptyPayload(t *testing.T) {
	var buf bytes.Buffer
	if err := Write(&buf, &Packet{Opcode: 0x1000}, nil, nil); err != nil {
		t.Fatalf("Write: %v", err)
	}

	got, err := Read(bufio.NewReader(&buf), nil, nil)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if got.Opcode != 0x1000 || len(got.Data) != 0 {
		t.Fatalf("unexpected packet: %+v", got)
	}
}

func TestReadRejectsEncryptedFlag(t *testing.T) {
	// Hand-build a frame with the real confirmed top Size-field bit set.
	frame := []byte{0x00, 0x80, 0x30, 0x01, 0x00, 0x00}
	_, err := Read(bufio.NewReader(bytes.NewReader(frame)), nil, nil)
	if err != ErrEncrypted {
		t.Fatalf("expected ErrEncrypted, got %v", err)
	}
}

func TestWriteRejectsOversizedPayload(t *testing.T) {
	p := &Packet{Opcode: 1, Data: make([]byte, 0x8000)}
	if err := Write(&bytes.Buffer{}, p, nil, nil); err == nil {
		t.Fatal("expected error for oversized payload, got nil")
	}
}

func TestWriteReadRoundTripWithSecurity(t *testing.T) {
	sendRoll := NewRollingByte(1, 2, 3)
	sendSum := NewPacketChecksum(7)
	recvRoll := NewRollingByte(1, 2, 3)
	recvSum := NewPacketChecksum(7)

	var buf bytes.Buffer
	want := &Packet{Opcode: 0x6100, Data: []byte("secured payload")}
	if err := Write(&buf, want, sendRoll, sendSum); err != nil {
		t.Fatalf("Write: %v", err)
	}

	got, err := Read(bufio.NewReader(&buf), recvRoll, recvSum)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if got.Opcode != want.Opcode || !bytes.Equal(got.Data, want.Data) {
		t.Fatalf("round trip mismatch: got %+v, want %+v", got, want)
	}
}

func TestReadRejectsRollingByteMismatch(t *testing.T) {
	sendRoll := NewRollingByte(1, 2, 3)
	recvRoll := NewRollingByte(9, 9, 9) // desynced seed

	var buf bytes.Buffer
	if err := Write(&buf, &Packet{Opcode: 1}, sendRoll, nil); err != nil {
		t.Fatalf("Write: %v", err)
	}
	if _, err := Read(bufio.NewReader(&buf), recvRoll, nil); err == nil {
		t.Fatal("expected rolling byte mismatch error, got nil")
	}
}

func TestReadRejectsChecksumMismatch(t *testing.T) {
	sendSum := NewPacketChecksum(7)
	recvSum := NewPacketChecksum(9) // different table

	var buf bytes.Buffer
	if err := Write(&buf, &Packet{Opcode: 1, Data: []byte("x")}, nil, sendSum); err != nil {
		t.Fatalf("Write: %v", err)
	}
	if _, err := Read(bufio.NewReader(&buf), nil, recvSum); err == nil {
		t.Fatal("expected checksum mismatch error, got nil")
	}
}
