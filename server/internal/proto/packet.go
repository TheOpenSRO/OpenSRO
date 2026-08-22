// Package proto implements the wire packet framing described in
// docs/protocol/PACKET_FORMAT.md. As of 2026-08-22 the header layout matches
// the real, confirmed original 6-byte shape (Size, Opcode, RollingByte,
// ChecksumByte, in that order — see PACKET_FORMAT.md for how each field's
// offset was confirmed from GatewayServer.exe), not the earlier 5-byte
// Size+Opcode+Security placeholder this package started with. It still
// doesn't implement the original's session key exchange or Blowfish payload
// encryption — RollingByte/ChecksumByte are threaded through as optional,
// session-scoped generators (nil is valid and means "no security state yet",
// e.g. before a handshake completes) rather than requiring a specific crypto
// scheme be wired up first. See the doc's Status section for what's left.
package proto

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
)

// headerSize is the real confirmed original header size: Size(2) + Opcode(2)
// + RollingByte(1) + ChecksumByte(1). See PACKET_FORMAT.md.
const headerSize = 6

// sizeFlagBit is the real confirmed top bit of the Size field (masked off
// with sizeMask to get the actual payload length) -- handshake.md confirmed
// the original reads Size masked with 0x7fff. What the flag itself means
// isn't confirmed yet (plausibly "encrypted payload"); ErrEncrypted below is
// raised whenever it's set, since this package can't decrypt yet either way.
const (
	sizeFlagBit = 1 << 15
	sizeMask    = sizeFlagBit - 1
)

// ErrEncrypted is returned by Read when a frame's Size field has the real
// confirmed top flag bit set, since payload decryption isn't implemented
// yet. Callers should treat this as "not supported yet", not malformed
// input.
var ErrEncrypted = errors.New("proto: encrypted packets not implemented")

// ErrMassivePacket is kept for callers that still reference it; no real,
// confirmed massive/split-packet flag has been located in the original
// header yet (the earlier "security byte" this package used to have was
// this project's own placeholder design, not a confirmed original field —
// see PACKET_FORMAT.md). Nothing in this package returns it currently.
var ErrMassivePacket = errors.New("proto: massive/split packets not implemented")

// Packet is one decoded frame's opcode and payload.
type Packet struct {
	Opcode uint16
	Data   []byte
}

// Read reads exactly one frame from r. roll and sum are the session's
// RollingByte/PacketChecksum generators; pass nil for either (or both)
// before session security state exists (e.g. pre-handshake) -- Read then
// skips validating that field instead of failing. When non-nil, a mismatch
// between the frame's byte and the generator's expected next value is
// reported as an error (the generators still advance/consume either way, to
// stay in sync with the sender).
func Read(r *bufio.Reader, roll *RollingByte, sum *PacketChecksum) (*Packet, error) {
	header := make([]byte, headerSize)
	if _, err := io.ReadFull(r, header); err != nil {
		return nil, err
	}

	rawSize := binary.LittleEndian.Uint16(header[0:2])
	opcode := binary.LittleEndian.Uint16(header[2:4])
	rollByte := header[4]
	checksumByte := header[5]

	if rawSize&sizeFlagBit != 0 {
		return nil, ErrEncrypted
	}
	size := rawSize & sizeMask

	data := make([]byte, size)
	if _, err := io.ReadFull(r, data); err != nil {
		return nil, fmt.Errorf("proto: reading %d-byte payload for opcode 0x%04x: %w", size, opcode, err)
	}

	if roll != nil {
		if want := roll.Next(); want != rollByte {
			return nil, fmt.Errorf("proto: rolling byte mismatch for opcode 0x%04x: got 0x%02x, want 0x%02x", opcode, rollByte, want)
		}
	}
	if sum != nil {
		for _, b := range data {
			sum.Update(b)
		}
		if want := sum.Byte(); want != checksumByte {
			return nil, fmt.Errorf("proto: checksum mismatch for opcode 0x%04x: got 0x%02x, want 0x%02x", opcode, checksumByte, want)
		}
	}

	return &Packet{Opcode: opcode, Data: data}, nil
}

// Write encodes and writes a single unencrypted frame. roll and sum follow
// the same nil-means-no-security-state convention as Read; when non-nil,
// each advances/updates exactly as the corresponding Read call on the peer
// side will expect.
func Write(w io.Writer, p *Packet, roll *RollingByte, sum *PacketChecksum) error {
	if len(p.Data) > sizeMask {
		return fmt.Errorf("proto: payload of %d bytes too large for a single frame", len(p.Data))
	}

	var rollByte, checksumByte byte
	if roll != nil {
		rollByte = roll.Next()
	}
	if sum != nil {
		for _, b := range p.Data {
			sum.Update(b)
		}
		checksumByte = sum.Byte()
	}

	header := make([]byte, headerSize)
	binary.LittleEndian.PutUint16(header[0:2], uint16(len(p.Data)))
	binary.LittleEndian.PutUint16(header[2:4], p.Opcode)
	header[4] = rollByte
	header[5] = checksumByte

	if _, err := w.Write(header); err != nil {
		return err
	}
	_, err := w.Write(p.Data)
	return err
}
