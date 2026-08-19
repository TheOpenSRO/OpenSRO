// Package proto implements the wire packet framing described in
// docs/protocol/PACKET_FORMAT.md: a small header (size, opcode, security
// flags) around an opcode-specific payload. It intentionally does not yet
// handle encrypted payloads, massive/split packets, or any specific opcode's
// contents — see the doc's Status section for what's implemented.
package proto

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
)

const headerSize = 5 // Size(2) + Opcode(2) + Security(1)

const (
	secEncrypted = 1 << 0
	secTrailer   = 1 << 1
	secMassive   = 1 << 2
)

// ErrMassivePacket is returned by Read when a frame's security byte marks it
// as part of a split/massive message, which this package doesn't reassemble
// yet.
var ErrMassivePacket = errors.New("proto: massive/split packets not implemented")

// ErrEncrypted is returned by Read when a frame is marked encrypted, since
// session crypto isn't implemented yet.
var ErrEncrypted = errors.New("proto: encrypted packets not implemented")

// Packet is one decoded, unencrypted frame.
type Packet struct {
	Opcode uint16
	Data   []byte
}

// Read reads exactly one frame from r. It returns ErrEncrypted or
// ErrMassivePacket for frames this package can't yet decode; callers should
// treat those as "not supported yet", not as malformed input.
func Read(r *bufio.Reader) (*Packet, error) {
	header := make([]byte, headerSize)
	if _, err := io.ReadFull(r, header); err != nil {
		return nil, err
	}

	size := binary.LittleEndian.Uint16(header[0:2])
	opcode := binary.LittleEndian.Uint16(header[2:4])
	security := header[4]

	if security&secMassive != 0 {
		return nil, ErrMassivePacket
	}
	if security&secEncrypted != 0 {
		return nil, ErrEncrypted
	}

	data := make([]byte, size)
	if _, err := io.ReadFull(r, data); err != nil {
		return nil, fmt.Errorf("proto: reading %d-byte payload for opcode 0x%04x: %w", size, opcode, err)
	}

	if security&secTrailer != 0 {
		trailer := make([]byte, 4)
		if _, err := io.ReadFull(r, trailer); err != nil {
			return nil, fmt.Errorf("proto: reading trailer for opcode 0x%04x: %w", opcode, err)
		}
		// CRC/count trailer is read past but not yet validated.
	}

	return &Packet{Opcode: opcode, Data: data}, nil
}

// Write encodes and writes a single unencrypted, non-massive frame.
func Write(w io.Writer, p *Packet) error {
	if len(p.Data) > 0xFFFF {
		return fmt.Errorf("proto: payload of %d bytes too large for a single frame", len(p.Data))
	}

	header := make([]byte, headerSize)
	binary.LittleEndian.PutUint16(header[0:2], uint16(len(p.Data)))
	binary.LittleEndian.PutUint16(header[2:4], p.Opcode)
	header[4] = 0 // unencrypted, no trailer, not massive

	if _, err := w.Write(header); err != nil {
		return err
	}
	_, err := w.Write(p.Data)
	return err
}
