// Package clientpacks is the server's half of "the server names the packs a
// client needs" (round 789, lane U; docs/protocol/asset_packs.md, "Server
// packs"). Everything here is OURS: retail has only its .pk2 archives and no
// such exchange.
//
// An operator puts the packs every player must have in one folder
// (-client-packs). At startup the server opens each one through assetfs with
// the readers' own checks, reads every entry back, hashes the file (SHA-256)
// and names the list, in the cascade order of rule 2, to any client that asks
// before login (session.ClientPacksHandler, OpClientPacks). The client
// downloads what it lacks -- from the operator's base URL (-client-packs-url)
// or from this server's own small HTTP listener (serve.go) -- verifies size
// and hash, and layers exactly those packs over its base archives.
package clientpacks

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"net/url"
	"regexp"
	"strings"

	"github.com/OpenSRO/OpenSRO/server/internal/assetfs"
)

// Version is the manifest's first byte. OURS.
const Version = 1

// The flag bits. OURS.
const (
	// FlagRequired: the server names its packs. The client layers exactly
	// these over its base archives (and sets its own packs and custom/
	// aside, unless FlagLocalExtras). Clear: no packs are named and the
	// client keeps its own set -- what a server without -client-packs sends.
	FlagRequired uint8 = 1 << 0
	// FlagLocalExtras: the client may keep its own packs (below the
	// server's) and its custom/ folder (on top, rule 1) too.
	FlagLocalExtras uint8 = 1 << 1
	knownFlags            = FlagRequired | FlagLocalExtras
)

// Bounds. OURS: the manifest is one frame (proto's payload is at most 0x7FFF
// bytes): 32 packs of a 64-byte name and a 512-byte URL take 20,224 bytes.
const (
	MaxPacks    = 32
	MaxNameLen  = 64
	MaxURLLen   = 512
	MaxPackSize = int64(4) << 30 // 4 GiB a pack; a converted Data.pk3 is 1.96 GB (asset_packs.md)
	MaxTotal    = int64(16) << 30
)

// Pack is one required pack as the wire names it.
type Pack struct {
	Name   string   // a file name: *.pk3 or *.zip, no folder (ValidName)
	Size   int64    // bytes
	SHA256 [32]byte // of the whole file
	// URL is where the client downloads it from ("" = only from the
	// server's own listener, Manifest.HTTPPort).
	URL string
}

// SHA256Hex is the hash in lower-case hex.
func (p Pack) SHA256Hex() string { return hex.EncodeToString(p.SHA256[:]) }

// Manifest is the OpClientPacks payload.
type Manifest struct {
	Required    bool
	LocalExtras bool
	// HTTPPort is the server's own pack listener's port on the gateway's
	// host (0: none).
	HTTPPort uint16
	Packs    []Pack // in rule 2's cascade order, lowest first: the client layers them so
}

// nameRe: ASCII letters, digits, `_`, `-` and `.`, not starting with a dot,
// ending .pk3 or .zip (any case). No separator, drive letter, colon, space or
// control character can appear, so a name can never leave the folder it is
// written to.
var nameRe = regexp.MustCompile(`^[A-Za-z0-9_-][A-Za-z0-9_.-]{0,59}\.(?i:pk3|zip)$`)

// ValidName says why `name` cannot be a server pack's name ("" when it can):
// rule 6's safety on the wire, plus rule 1's base names (a pack named Data.pk3
// would be read as a base archive, not a pack).
func ValidName(name string) string {
	switch {
	case len(name) == 0 || len(name) > MaxNameLen:
		return fmt.Sprintf("a pack name is 1-%d bytes", MaxNameLen)
	case !nameRe.MatchString(name):
		return "a pack name is letters, digits, _ - and . (not first), ending .pk3 or .zip"
	case strings.Contains(name, ".."):
		return "a pack name may not hold \"..\""
	}
	stem := name[:len(name)-4]
	for _, b := range assetfs.BaseNames {
		if strings.EqualFold(b, stem) {
			return fmt.Sprintf("%q is a base archive's name, not a pack's", name)
		}
	}
	return ""
}

// ValidURL says why `raw` cannot be a pack's URL ("" when it can): http or
// https, printable ASCII without spaces, a host, no user name or password,
// no fragment. Which hosts a client accepts plain http from is the client's
// rule (asset_packs.md, "Server packs").
func ValidURL(raw string) string {
	if len(raw) > MaxURLLen {
		return fmt.Sprintf("a URL is at most %d bytes", MaxURLLen)
	}
	for i := 0; i < len(raw); i++ {
		if raw[i] <= 0x20 || raw[i] >= 0x7f {
			return "a URL is printable ASCII without spaces"
		}
	}
	u, err := url.Parse(raw)
	switch {
	case err != nil:
		return "not a URL: " + err.Error()
	case u.Scheme != "http" && u.Scheme != "https":
		return "a URL is http:// or https://"
	case u.Host == "" || u.Hostname() == "":
		return "a URL names a host"
	case u.User != nil:
		return "a URL may not carry a user name or password"
	case u.Fragment != "" || strings.Contains(raw, "#"):
		return "a URL may not carry a fragment"
	}
	return ""
}

// Check says why m cannot go on the wire (nil when it can).
func (m Manifest) Check() error {
	if !m.Required {
		if len(m.Packs) > 0 || m.LocalExtras || m.HTTPPort != 0 {
			return fmt.Errorf("clientpacks: a manifest that names no packs carries no packs, extras or port")
		}
		return nil
	}
	if len(m.Packs) > MaxPacks {
		return fmt.Errorf("clientpacks: %d packs, at most %d", len(m.Packs), MaxPacks)
	}
	seen := map[string]bool{}
	var total int64
	for _, p := range m.Packs {
		if why := ValidName(p.Name); why != "" {
			return fmt.Errorf("clientpacks: pack %q: %s", p.Name, why)
		}
		k := strings.ToLower(p.Name)
		if seen[k] {
			return fmt.Errorf("clientpacks: pack %q named twice (case ignored)", p.Name)
		}
		seen[k] = true
		if p.Size < 1 || p.Size > MaxPackSize {
			return fmt.Errorf("clientpacks: pack %q: size %d, want 1-%d", p.Name, p.Size, MaxPackSize)
		}
		total += p.Size
		if p.URL != "" {
			if why := ValidURL(p.URL); why != "" {
				return fmt.Errorf("clientpacks: pack %q: URL %q: %s", p.Name, p.URL, why)
			}
		} else if m.HTTPPort == 0 {
			return fmt.Errorf("clientpacks: pack %q has no URL and the server serves no files", p.Name)
		}
	}
	if total > MaxTotal {
		return fmt.Errorf("clientpacks: the packs total %d bytes, at most %d", total, MaxTotal)
	}
	return nil
}

// Encode serializes the OpClientPacks payload, all little-endian:
//
//	u8 version (1) | u8 flags | u16 http_port | u8 count |
//	count x ( u8 name_len | name | u64 size | sha256[32] | u16 url_len | url )
//
// It refuses a manifest Check refuses, so nothing unsafe reaches the wire.
func (m Manifest) Encode() ([]byte, error) {
	if err := m.Check(); err != nil {
		return nil, err
	}
	var b bytes.Buffer
	var flags uint8
	if m.Required {
		flags |= FlagRequired
	}
	if m.LocalExtras {
		flags |= FlagLocalExtras
	}
	b.WriteByte(Version)
	b.WriteByte(flags)
	_ = binary.Write(&b, binary.LittleEndian, m.HTTPPort)
	b.WriteByte(uint8(len(m.Packs)))
	for _, p := range m.Packs {
		b.WriteByte(uint8(len(p.Name)))
		b.WriteString(p.Name)
		_ = binary.Write(&b, binary.LittleEndian, uint64(p.Size))
		b.Write(p.SHA256[:])
		_ = binary.Write(&b, binary.LittleEndian, uint16(len(p.URL)))
		b.WriteString(p.URL)
	}
	return b.Bytes(), nil
}

// Decode parses an OpClientPacks payload strictly: version 1, no unknown
// flag bit, no trailing byte, and everything Check asks.
func Decode(data []byte) (Manifest, error) {
	var m Manifest
	r := bytes.NewReader(data)
	fail := func(why string) (Manifest, error) {
		return Manifest{}, fmt.Errorf("clientpacks: decoding the manifest: %s", why)
	}
	var head struct {
		Version uint8
		Flags   uint8
		Port    uint16
		Count   uint8
	}
	if err := binary.Read(r, binary.LittleEndian, &head); err != nil {
		return fail("truncated header")
	}
	if head.Version != Version {
		return fail(fmt.Sprintf("version %d, want %d", head.Version, Version))
	}
	if head.Flags&^knownFlags != 0 {
		return fail(fmt.Sprintf("unknown flag bits 0x%02x", head.Flags&^knownFlags))
	}
	m.Required = head.Flags&FlagRequired != 0
	m.LocalExtras = head.Flags&FlagLocalExtras != 0
	m.HTTPPort = head.Port
	if int(head.Count) > MaxPacks {
		return fail(fmt.Sprintf("%d packs, at most %d", head.Count, MaxPacks))
	}
	for i := 0; i < int(head.Count); i++ {
		var p Pack
		n, err := r.ReadByte()
		if err != nil {
			return fail(fmt.Sprintf("pack %d: truncated name length", i))
		}
		name := make([]byte, n)
		if _, err := ioReadFull(r, name); err != nil {
			return fail(fmt.Sprintf("pack %d: truncated name", i))
		}
		p.Name = string(name)
		var size uint64
		if err := binary.Read(r, binary.LittleEndian, &size); err != nil {
			return fail(fmt.Sprintf("pack %d: truncated size", i))
		}
		if size > uint64(MaxPackSize) {
			return fail(fmt.Sprintf("pack %d: size %d, at most %d", i, size, MaxPackSize))
		}
		p.Size = int64(size)
		if _, err := ioReadFull(r, p.SHA256[:]); err != nil {
			return fail(fmt.Sprintf("pack %d: truncated hash", i))
		}
		var ul uint16
		if err := binary.Read(r, binary.LittleEndian, &ul); err != nil {
			return fail(fmt.Sprintf("pack %d: truncated URL length", i))
		}
		if int(ul) > MaxURLLen {
			return fail(fmt.Sprintf("pack %d: URL of %d bytes, at most %d", i, ul, MaxURLLen))
		}
		u := make([]byte, ul)
		if _, err := ioReadFull(r, u); err != nil {
			return fail(fmt.Sprintf("pack %d: truncated URL", i))
		}
		p.URL = string(u)
		m.Packs = append(m.Packs, p)
	}
	if r.Len() != 0 {
		return fail(fmt.Sprintf("%d trailing byte(s)", r.Len()))
	}
	if err := m.Check(); err != nil {
		return Manifest{}, err
	}
	return m, nil
}

func ioReadFull(r *bytes.Reader, b []byte) (int, error) {
	if len(b) == 0 {
		return 0, nil // bytes.Reader answers io.EOF to an empty read at its end
	}
	if r.Len() < len(b) {
		return 0, fmt.Errorf("short")
	}
	return r.Read(b)
}
