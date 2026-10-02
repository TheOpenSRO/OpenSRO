package proto

// The original protocol's frame, both ways, as READ from the retail client's
// network engine (round 681; docs/protocol/opcodes/handshake.md):
//
//	u16 size     payload length; bit 15 set = the rest is Blowfish-encrypted
//	u16 opcode
//	u8  count    the rolling byte (client -> server only; 0 from a server)
//	u8  check    the checksum byte (likewise)
//	... payload
//
// Sending (sro_client 0x4b0d70): with security on (handshake flag 4) a
// client fills count from the rolling byte, zeroes check, checksums the whole
// plain frame -- header with the size word as sent, bit 15 included -- and
// stores the result in check; then, with Blowfish on (flag 2) and bit 15 set,
// it encrypts bytes 2.. (opcode, count, check, payload) zero-padded to whole
// 8-byte blocks, so an encrypted frame is 2 + PaddedLen(size + 4) bytes.
//
// Receiving (sro_client 0x4b0f60): bit 15 without Blowfish is error 0x8011;
// an encrypted frame longer than 0x1000 bytes is 0x800d; with security on, a
// server checks count then check (0x800b, 0x800c) and a CLIENT requires both
// bytes to be 0 -- except for an unencrypted 0x1001.

import (
	"encoding/binary"
	"errors"
	"fmt"
)

// RetailMaxFrame bounds one frame on the wire (READ for encrypted frames,
// above; OURS applied to plain ones too: no gateway message read here comes
// near it).
const RetailMaxFrame = 0x1000

// RetailEncrypted is the size word's encryption bit.
const RetailEncrypted = 0x8000

// Retail handshake flag bits (READ, sro_client 0x4b1da0 and 0x4b0cc0).
const (
	RetailFlagNone      = 0x01 // skip all set-up (not supported here)
	RetailFlagBlowfish  = 0x02 // an 8-byte Blowfish key follows
	RetailFlagSecurity  = 0x04 // count seed and crc seed follow
	RetailFlagHandshake = 0x08 // the key exchange follows (key, G, P, A)
	RetailFlagChallenge = 0x10 // the server's 8-byte challenge
)

var (
	// ErrRetailNeedMore means the buffer does not hold a whole frame yet.
	ErrRetailNeedMore = errors.New("retail: incomplete frame")
)

// RetailSecurity is one connection's negotiated state, either side.
type RetailSecurity struct {
	Flags  byte
	Count  [3]byte
	CRC    *[256]uint32
	Cipher *RetailCipher
}

// Secured reports whether frames carry count and check bytes.
func (s *RetailSecurity) Secured() bool { return s != nil && s.Flags&RetailFlagSecurity != 0 }

// Encrypting reports whether Blowfish is on.
func (s *RetailSecurity) Encrypting() bool {
	return s != nil && s.Flags&RetailFlagBlowfish != 0 && s.Cipher != nil
}

// RetailFrameLen is the wire length of the frame starting buf, or
// ErrRetailNeedMore, or an error for a frame over RetailMaxFrame.
func RetailFrameLen(buf []byte) (int, error) {
	if len(buf) < 2 {
		return 0, ErrRetailNeedMore
	}
	raw := binary.LittleEndian.Uint16(buf)
	size := int(raw &^ RetailEncrypted)
	n := 6 + size
	if raw&RetailEncrypted != 0 {
		n = 2 + PaddedLen(size+4)
	}
	if n > RetailMaxFrame {
		return 0, fmt.Errorf("retail: a %d-byte frame (size word 0x%04x) is over %d", n, raw, RetailMaxFrame)
	}
	if len(buf) < n {
		return n, ErrRetailNeedMore
	}
	return n, nil
}

// RetailFrame is one decoded frame.
type RetailFrame struct {
	Opcode    uint16
	Payload   []byte
	Encrypted bool
	Count     byte
	Check     byte
	// Plain is the frame as checksummed: header (check zero) + payload.
	Plain []byte
}

// DecodeRetailFrame decodes exactly one whole frame (len(frame) from
// RetailFrameLen), decrypting it with sec when it is encrypted. It checks
// nothing about the security bytes; see CheckFromServer / CheckFromClient.
func DecodeRetailFrame(frame []byte, sec *RetailSecurity) (*RetailFrame, error) {
	if len(frame) < 6 {
		return nil, fmt.Errorf("retail: a %d-byte frame is shorter than its header", len(frame))
	}
	raw := binary.LittleEndian.Uint16(frame)
	size := int(raw &^ RetailEncrypted)
	body := frame[2:]
	enc := raw&RetailEncrypted != 0
	if enc {
		if !sec.Encrypting() {
			return nil, fmt.Errorf("retail: an encrypted frame before Blowfish was agreed (the client's error 0x8011)")
		}
		if len(body) != PaddedLen(size+4) {
			return nil, fmt.Errorf("retail: encrypted frame body %d bytes, want %d", len(body), PaddedLen(size+4))
		}
		body = sec.Cipher.Decrypt(body)
	} else if len(body) != size+4 {
		return nil, fmt.Errorf("retail: frame body %d bytes, want %d", len(body), size+4)
	}
	f := &RetailFrame{
		Opcode:    binary.LittleEndian.Uint16(body[0:]),
		Count:     body[2],
		Check:     body[3],
		Encrypted: enc,
	}
	f.Payload = append([]byte(nil), body[4:4+size]...)
	f.Plain = make([]byte, 6+size)
	binary.LittleEndian.PutUint16(f.Plain, raw)
	copy(f.Plain[2:], body[:4+size])
	f.Plain[5] = 0
	return f, nil
}

// CheckFromServer applies the client's rule to a frame a server sent (READ,
// 0x4b0f60 client branch): with security on, count and check must both be 0,
// except on an unencrypted 0x1001.
func (s *RetailSecurity) CheckFromServer(f *RetailFrame) error {
	if !s.Secured() || (!f.Encrypted && f.Opcode == 0x1001) {
		return nil
	}
	if f.Count != 0 {
		return fmt.Errorf("retail: opcode 0x%04x from the server has count byte 0x%02x, not 0 (the client's error 0x800b)", f.Opcode, f.Count)
	}
	if f.Check != 0 {
		return fmt.Errorf("retail: opcode 0x%04x from the server has check byte 0x%02x, not 0 (the client's error 0x800c)", f.Opcode, f.Check)
	}
	return nil
}

// CheckFromClient applies the server's rule to a client's frame (READ,
// 0x4b0f60 server branch): the next rolling byte, then the checksum. The
// rolling byte advances either way.
func (s *RetailSecurity) CheckFromClient(f *RetailFrame) error {
	if !s.Secured() || (!f.Encrypted && f.Opcode == 0x1001) {
		return nil
	}
	if want := NextCountByte(&s.Count); f.Count != want {
		return fmt.Errorf("retail: opcode 0x%04x count byte 0x%02x, want 0x%02x (error 0x800b)", f.Opcode, f.Count, want)
	}
	if s.CRC == nil {
		return fmt.Errorf("retail: no checksum table")
	}
	if want := CheckByte(s.CRC, f.Plain); f.Check != want {
		return fmt.Errorf("retail: opcode 0x%04x check byte 0x%02x, want 0x%02x (error 0x800c)", f.Opcode, f.Check, want)
	}
	return nil
}

// EncodeClientFrame builds a client's frame: security bytes when secured,
// then encryption when asked and Blowfish is on. A frame asked encrypted
// without Blowfish goes plain with bit 15 clear (OURS: the client logs and
// clears the bit AFTER checksumming with it set, 0x4b0d70, which no server
// could verify).
func (s *RetailSecurity) EncodeClientFrame(op uint16, payload []byte, encrypt bool) ([]byte, error) {
	return s.encode(op, payload, encrypt, true)
}

// EncodeServerFrame builds a server's frame: count and check 0 (READ, the
// server branch of 0x4b0d70 writes zeros), encrypted when asked.
func (s *RetailSecurity) EncodeServerFrame(op uint16, payload []byte, encrypt bool) ([]byte, error) {
	return s.encode(op, payload, encrypt, false)
}

func (s *RetailSecurity) encode(op uint16, payload []byte, encrypt, client bool) ([]byte, error) {
	if len(payload) > RetailMaxFrame {
		return nil, fmt.Errorf("retail: a %d-byte payload is over %d", len(payload), RetailMaxFrame)
	}
	enc := encrypt && s.Encrypting()
	raw := uint16(len(payload))
	if enc {
		raw |= RetailEncrypted
	}
	plain := make([]byte, 6+len(payload))
	binary.LittleEndian.PutUint16(plain, raw)
	binary.LittleEndian.PutUint16(plain[2:], op)
	copy(plain[6:], payload)
	if client && s.Secured() {
		if s.CRC == nil {
			return nil, fmt.Errorf("retail: no checksum table")
		}
		plain[4] = NextCountByte(&s.Count)
		plain[5] = CheckByte(s.CRC, plain)
	}
	if !enc {
		return plain, nil
	}
	out := make([]byte, 2, 2+PaddedLen(len(plain)-2))
	copy(out, plain[:2])
	return append(out, s.Cipher.Encrypt(plain[2:])...), nil
}
