package session

import (
	"encoding/binary"
	"errors"
	"fmt"
)

// This file holds payload encoding helpers shared across this package's
// opcodes (login.go, register.go, character.go) — the small length-prefixed
// binary shape used throughout our own protocol. See
// docs/protocol/PROTOCOL_DECISION.md for why this is a fresh, simple design
// rather than anything derived from the original game's wire format.

// encodeOKReason serializes the common "did it work" result shape used by
// several opcodes: one byte (0/1) then a length-prefixed reason string.
func encodeOKReason(ok bool, reason string) []byte {
	out := make([]byte, 0, 3+len(reason))
	if ok {
		out = append(out, 1)
	} else {
		out = append(out, 0)
	}
	return append(out, encodeStrings(reason)...)
}

// decodeOKReason parses the shape encodeOKReason produces.
func decodeOKReason(data []byte) (ok bool, reason string, err error) {
	if len(data) < 1 {
		return false, "", errors.New("empty payload")
	}
	fields, err := decodeStrings(data[1:], 1)
	if err != nil {
		return false, "", err
	}
	return data[0] != 0, fields[0], nil
}

// encodeStrings serializes each field as a uint16 LE byte length followed
// by that many UTF-8 bytes.
func encodeStrings(fields ...string) []byte {
	var out []byte
	for _, f := range fields {
		lenBuf := make([]byte, 2)
		binary.LittleEndian.PutUint16(lenBuf, uint16(len(f)))
		out = append(out, lenBuf...)
		out = append(out, f...)
	}
	return out
}

// decodeStrings parses exactly count length-prefixed strings from data,
// requiring data to contain nothing else after them.
func decodeStrings(data []byte, count int) ([]string, error) {
	fields, rest, err := decodeStringsPrefix(data, count)
	if err != nil {
		return nil, err
	}
	if len(rest) != 0 {
		return nil, fmt.Errorf("%d unexpected trailing byte(s) after %d field(s)", len(rest), count)
	}
	return fields, nil
}

// decodeStringsPrefix parses count length-prefixed strings from the front
// of data and returns them along with whatever bytes remain — for payloads
// that have more structure after the strings (e.g. CharacterListResult's
// name count + names, which follow a single Error string).
func decodeStringsPrefix(data []byte, count int) (fields []string, rest []byte, err error) {
	out := make([]string, 0, count)
	for i := 0; i < count; i++ {
		if len(data) < 2 {
			return nil, nil, fmt.Errorf("field %d: truncated length prefix", i)
		}
		n := binary.LittleEndian.Uint16(data)
		data = data[2:]
		if int(n) > len(data) {
			return nil, nil, fmt.Errorf("field %d: declared length %d exceeds remaining %d bytes", i, n, len(data))
		}
		out = append(out, string(data[:n]))
		data = data[n:]
	}
	return out, data, nil
}
