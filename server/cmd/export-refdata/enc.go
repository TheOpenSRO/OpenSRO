package main

// The ENC skill tables (round 785): the files the retail client loads.
//
// READ (sro_client.exe, docs/protocol/magic_state_board.md "Where the flags
// come from"): Client_LoadAllRefData (0x844cd0) loads the list
// `textdata\skilldataenc.txt`, which names SkillData_1000ENC.txt ..
// SkillData_47000ENC.txt. A file ending in the UTF-16 trailer "\r\n//encrypt"
// is decrypted by 0x4f5140(buffer, size, 0x8c1f, offset): for each byte at
// file position p, with k = 0x8c1f + p,
//
//	byte += T2[k % 0xa7] - T1[k % 0x1ef]
//
// where T1 is the 495 bytes at VA 0xeae758 and T2 the 167 bytes at VA
// 0xeae948 in the executable's .data. The key tables are the PLAYER'S OWN
// executable's and are never copied into this repo: the exporter reads them
// out of the sro_client.exe the operator names with -enc-exe, as the client
// reads its own archive.
//
// MEASURED (round 785, the RE box): decrypting SkillData_1000ENC.txt this way
// gives a file byte-identical to its plain twin skilldata_1000.txt, and two
// client builds (md5 2a5794b7..., 27528cb7...) carry identical tables at
// those addresses. A decrypted file must start with the UTF-16LE BOM FF FE;
// encDecrypt checks that, so a client whose tables sit elsewhere fails loudly
// rather than exporting garbage.

import (
	"bytes"
	"debug/pe"
	"fmt"
)

const (
	encKeyT1VA  = 0xeae758
	encKeyT1Len = 0x1ef // 495
	encKeyT2VA  = 0xeae948
	encKeyT2Len = 0xa7 // 167
	encSeed     = 0x8c1f
)

// encTrailer is "\r\n//encrypt" in UTF-16LE, the marker an ENC file ends in.
var encTrailer = []byte{'\r', 0, '\n', 0, '/', 0, '/', 0, 'e', 0, 'n', 0, 'c', 0, 'r', 0, 'y', 0, 'p', 0, 't', 0}

// encKeys holds the two tables once -enc-exe has been read.
type encKeys struct {
	t1, t2 []byte
}

var loadedEncKeys *encKeys

// loadEncKeys reads T1 and T2 out of the operator's sro_client.exe.
func loadEncKeys(exePath string) (*encKeys, error) {
	f, err := pe.Open(exePath)
	if err != nil {
		return nil, fmt.Errorf("opening %s: %w", exePath, err)
	}
	defer f.Close()
	var base uint32
	switch oh := f.OptionalHeader.(type) {
	case *pe.OptionalHeader32:
		base = oh.ImageBase
	default:
		return nil, fmt.Errorf("%s: not a 32-bit PE", exePath)
	}
	read := func(va uint32, n int) ([]byte, error) {
		rva := va - base
		for _, s := range f.Sections {
			if rva >= s.VirtualAddress && rva+uint32(n) <= s.VirtualAddress+s.Size {
				data, err := s.Data()
				if err != nil {
					return nil, err
				}
				off := rva - s.VirtualAddress
				return append([]byte(nil), data[off:off+uint32(n)]...), nil
			}
		}
		return nil, fmt.Errorf("%s: VA 0x%x is in no section", exePath, va)
	}
	t1, err := read(encKeyT1VA, encKeyT1Len)
	if err != nil {
		return nil, err
	}
	t2, err := read(encKeyT2VA, encKeyT2Len)
	if err != nil {
		return nil, err
	}
	return &encKeys{t1: t1, t2: t2}, nil
}

// isEncrypted reports whether raw is an ENC file (ends in the trailer).
func isEncrypted(raw []byte) bool { return bytes.HasSuffix(raw, encTrailer) }

// encDecrypt strips the trailer and decrypts raw with k (0x4f5140's loop).
func encDecrypt(raw []byte, k *encKeys) ([]byte, error) {
	body := append([]byte(nil), raw[:len(raw)-len(encTrailer)]...)
	for p := range body {
		key := encSeed + p
		body[p] += k.t2[key%encKeyT2Len] - k.t1[key%encKeyT1Len]
	}
	if len(body) < 2 || body[0] != 0xFF || body[1] != 0xFE {
		return nil, fmt.Errorf("decrypted text has no UTF-16 BOM: the key tables in this sro_client.exe are not at 0x%x/0x%x", encKeyT1VA, encKeyT2VA)
	}
	return body, nil
}

// readRaw reads path, decrypting an ENC file with the loaded keys.
func readRaw(path string) ([]byte, error) {
	raw, err := inputs.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if !isEncrypted(raw) {
		return raw, nil
	}
	if loadedEncKeys == nil {
		return nil, fmt.Errorf("%s is an encrypted (ENC) table: pass -enc-exe <your sro_client.exe> so the exporter can read it", path)
	}
	return encDecrypt(raw, loadedEncKeys)
}
