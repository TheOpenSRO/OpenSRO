package session

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"unicode/utf8"

	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
)

// The operator's front-end theme (round 678). OURS: this whole exchange is
// this project's own design, not a recovered retail one. A private-server
// operator brands the client's login screen -- which title intro plays, the
// title music, a logo, a line of copyright text, the art of the screen's top
// and bottom bands -- and the server hands that
// to any client that asks, BEFORE login: the client opens a short-lived
// connection of its own at boot, sends OpFrontEndThemeRequest, waits a moment
// for OpFrontEndTheme, and closes. No authentication is needed and nothing
// about the session changes.
//
// Every value is a name the client resolves inside a fixed folder of its own
// (an intro under the archive's script\intro\ or the client's
// custom/intro/, a logo or band art under custom/frontend/, the music beside
// the other title music), so a name is validated here against a strict pattern and
// must never be able to step out of that folder; an invalid one is dropped
// (served as "", the client's own default) with a warning at startup.
const (
	OpFrontEndThemeRequest uint16 = 0x0005 // client -> server, empty payload
	OpFrontEndTheme        uint16 = 0x0006 // server -> client
)

// FrontEndThemeVersion is the "v" every OpFrontEndTheme carries. OURS.
const FrontEndThemeVersion = 1

// FrontEndCopyrightMaxRunes bounds the copyright line (after trimming and
// removing control characters). OURS: a one-line band of text, not a page.
const FrontEndCopyrightMaxRunes = 200

// RetailIntroNames are the title intros the retail Media.pk2 carries, as the
// file names under script\intro\ (without the .txt). READ from the archive's
// directory listing; "china_whatf" is the real (misspelt) retail file name,
// listed beside "china_wharf". A valid intro name outside this list is an
// operator's own, which the client looks for in custom/intro/<name>.txt.
var RetailIntroNames = []string{
	"roc", "egypt", "china_whatf", "china_wharf", "constantinople",
	"rm", "rmzh", "jupiter_login", "ruby_baghdad",
}

var (
	introShortName = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)
	// The full archive path spelling: script\intro\<name>.txt, the prefix
	// and extension in any case. The name allows a space (but no dot or
	// separator), so neither ".." nor a further folder can appear in it.
	introArchivePath = regexp.MustCompile(`(?i)^script\\intro\\([A-Za-z0-9_ -]{1,64})\.txt$`)
	bgmName          = regexp.MustCompile(`(?i)^[A-Za-z0-9_ .-]{1,64}\.ogg$`)
	// A logo and the band art: one pattern for the three images.
	imageName = regexp.MustCompile(`(?i)^[A-Za-z0-9_-]{1,64}\.(png|ddj)$`)
)

// FrontEndTheme is what the server serves before login. An empty field means
// "not set": the client uses its own default (option.txt's IntroName and
// IntroBGM, the archive's own logo and band art, no copyright line). OURS.
type FrontEndTheme struct {
	// Intro: a retail short name (RetailIntroNames), an operator's own name
	// (custom/intro/<name>.txt on the client), or an archive path
	// script\intro\<name>.txt.
	Intro string
	// BGM: the title music's file name, e.g. maintheme_cut.ogg.
	BGM string
	// Logo: a file name inside the client's custom/frontend/ folder.
	Logo string
	// Copyright: one line of text for the bottom band.
	Copyright string
	// BandTop and BandBottom: the art of the screen's top and bottom bands,
	// file names inside the client's custom/frontend/ folder.
	BandTop    string
	BandBottom string
}

// IsDefault reports whether nothing is set: the client shows its defaults.
func (t FrontEndTheme) IsDefault() bool {
	return t == FrontEndTheme{}
}

// NewFrontEndTheme validates an operator's settings (raw, as typed) and
// returns the theme to serve, plus the lines worth telling the operator at startup: warnings for
// values that were dropped or changed, infos for valid values the client may
// still not be able to resolve. Every input is trimmed of surrounding white
// space first. It never fails: an invalid value is served as "".
func NewFrontEndTheme(raw FrontEndTheme) (theme FrontEndTheme, warnings, infos []string) {
	intro := strings.TrimSpace(raw.Intro)
	bgm := strings.TrimSpace(raw.BGM)

	switch {
	case intro == "":
	case introShortName.MatchString(intro):
		theme.Intro = intro
		if !isRetailIntro(intro) {
			infos = append(infos, fmt.Sprintf("front-end intro %q is not a retail intro: the client must have custom/intro/%s.txt, or it falls back to option.txt's IntroName", intro, intro))
		}
	case introArchivePath.MatchString(intro):
		theme.Intro = intro
		name := introArchivePath.FindStringSubmatch(intro)[1]
		if !isRetailIntro(name) {
			infos = append(infos, fmt.Sprintf("front-end intro %q names no retail intro: the archive must carry it, or the client falls back to option.txt's IntroName", intro))
		}
	default:
		warnings = append(warnings, fmt.Sprintf("front-end intro %q is not a valid intro name (letters, digits, _ and - only, or script\\intro\\<name>.txt); serving none, the client uses option.txt's IntroName", intro))
	}

	switch {
	case bgm == "":
	case bgmName.MatchString(bgm) && !strings.Contains(bgm, ".."):
		theme.BGM = bgm
	default:
		warnings = append(warnings, fmt.Sprintf("front-end bgm %q is not a valid music file name (letters, digits, space, _ . -, ending .ogg, no \"..\"); serving none, the client uses option.txt's IntroBGM", bgm))
	}

	theme.Logo, warnings = imageSetting("logo", raw.Logo, "logo", warnings)
	theme.Copyright, warnings = sanitizeCopyright(raw.Copyright, warnings)
	theme.BandTop, warnings = imageSetting("band_top", raw.BandTop, "top band art", warnings)
	theme.BandBottom, warnings = imageSetting("band_bottom", raw.BandBottom, "bottom band art", warnings)
	return theme, warnings, infos
}

// imageSetting validates one image name the client loads from its
// custom/frontend/ folder: the name, trimmed, or "" with a warning.
func imageSetting(key, value, what string, warnings []string) (string, []string) {
	value = strings.TrimSpace(value)
	if value == "" || imageName.MatchString(value) {
		return value, warnings
	}
	return "", append(warnings, fmt.Sprintf("front-end %s %q is not a valid image file name (letters, digits, _ and -, ending .png or .ddj); serving none, the client shows the archive's own %s", key, value, what))
}

func isRetailIntro(name string) bool {
	for _, r := range RetailIntroNames {
		if strings.EqualFold(r, name) {
			return true
		}
	}
	return false
}

// sanitizeCopyright makes the copyright one clean line: invalid UTF-8 and
// control characters (below 0x20, and 0x7f) removed, surrounding white space
// trimmed, at most FrontEndCopyrightMaxRunes runes.
func sanitizeCopyright(s string, warnings []string) (string, []string) {
	clean := strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, strings.ToValidUTF8(s, ""))
	// Only a removal the trim would not have made anyway is worth a warning:
	// an env file's trailing newline is not.
	if strings.TrimSpace(s) != strings.TrimSpace(clean) {
		warnings = append(warnings, "front-end copyright had control characters or invalid UTF-8; they were removed")
	}
	clean = strings.TrimSpace(clean)
	if n := utf8.RuneCountInString(clean); n > FrontEndCopyrightMaxRunes {
		clean = strings.TrimSpace(string([]rune(clean)[:FrontEndCopyrightMaxRunes]))
		warnings = append(warnings, fmt.Sprintf("front-end copyright is %d characters; truncated to %d", n, FrontEndCopyrightMaxRunes))
	}
	return clean, warnings
}

// frontEndThemeJSON is the wire object, in the wire's key order. CharSelect
// and Create are reserved for later rounds (the character-select and
// creation scenes) and are always null in version 1.
type frontEndThemeJSON struct {
	V          int              `json:"v"`
	Intro      string           `json:"intro"`
	BGM        string           `json:"bgm"`
	Logo       string           `json:"logo"`
	Copyright  string           `json:"copyright"`
	BandTop    string           `json:"band_top"`
	BandBottom string           `json:"band_bottom"`
	CharSelect *json.RawMessage `json:"charselect"`
	Create     *json.RawMessage `json:"create"`
}

// JSON returns the theme as the wire's JSON object:
//
//	{"v":1,"intro":"...","bgm":"...","logo":"...","copyright":"...",
//	 "band_top":"...","band_bottom":"...","charselect":null,"create":null}
//
// exactly these keys, always present, in this order, HTML characters not
// escaped. The theme is re-validated first, so a FrontEndTheme built by hand
// with an unsafe name can never reach the wire (its bad fields go out "").
func (t FrontEndTheme) JSON() []byte {
	s, _, _ := NewFrontEndTheme(t)
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	// Encoding a struct of strings and nil pointers cannot fail.
	_ = enc.Encode(frontEndThemeJSON{V: FrontEndThemeVersion, Intro: s.Intro, BGM: s.BGM, Logo: s.Logo,
		Copyright: s.Copyright, BandTop: s.BandTop, BandBottom: s.BandBottom})
	return bytes.TrimRight(buf.Bytes(), "\n")
}

// Encode serializes the OpFrontEndTheme payload: a uint16 LE byte length,
// then that many UTF-8 bytes of JSON(). A validated theme is well under the
// uint16 limit (six short names and 200 runes).
func (t FrontEndTheme) Encode() []byte {
	j := t.JSON()
	out := make([]byte, 2, 2+len(j))
	binary.LittleEndian.PutUint16(out, uint16(len(j)))
	return append(out, j...)
}

// DecodeFrontEndTheme parses an OpFrontEndTheme payload, strictly: the
// declared length must match the bytes that follow, the object must carry
// version 1 and no keys but the nine, and the reserved slots must be null.
func DecodeFrontEndTheme(data []byte) (FrontEndTheme, error) {
	if len(data) < 2 {
		return FrontEndTheme{}, fmt.Errorf("session: decoding FrontEndTheme: truncated length prefix")
	}
	n := int(binary.LittleEndian.Uint16(data))
	if n != len(data)-2 {
		return FrontEndTheme{}, fmt.Errorf("session: decoding FrontEndTheme: declared length %d, %d bytes follow", n, len(data)-2)
	}
	dec := json.NewDecoder(bytes.NewReader(data[2:]))
	dec.DisallowUnknownFields()
	var w struct {
		frontEndThemeJSON
		V *int `json:"v"`
	}
	if err := dec.Decode(&w); err != nil {
		return FrontEndTheme{}, fmt.Errorf("session: decoding FrontEndTheme: %w", err)
	}
	if w.V == nil || *w.V != FrontEndThemeVersion {
		return FrontEndTheme{}, fmt.Errorf("session: decoding FrontEndTheme: not version %d", FrontEndThemeVersion)
	}
	if w.CharSelect != nil || w.Create != nil {
		return FrontEndTheme{}, fmt.Errorf("session: decoding FrontEndTheme: charselect and create must be null in version %d", FrontEndThemeVersion)
	}
	return FrontEndTheme{Intro: w.Intro, BGM: w.BGM, Logo: w.Logo, Copyright: w.Copyright,
		BandTop: w.BandTop, BandBottom: w.BandBottom}, nil
}

// FrontEndThemeHandler returns a gateway.Handler that answers
// OpFrontEndThemeRequest (any payload, ignored) with OpFrontEndTheme carrying
// theme. It needs no login and touches no session state; other opcodes are
// ignored, as every handler in the chain does. OURS.
//
// Round 678's review: one answer per connection. The client asks on a
// connection of its own, so an unauthenticated session that asked is ended
// after its answer is written (gateway.ErrEndSession: drained, closed, no
// WARN); a logged-in session that asks gets one answer and nothing for a
// repeat. Nothing is logged per request.
func FrontEndThemeHandler(theme FrontEndTheme) gateway.Handler {
	payload := theme.Encode()
	return func(_ context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpFrontEndThemeRequest {
			return nil
		}
		if _, answered := sess.Get(frontEndThemeAnsweredKey); answered {
			return nil
		}
		sess.Set(frontEndThemeAnsweredKey, true)
		if err := sess.Send(&proto.Packet{Opcode: OpFrontEndTheme, Data: payload}); err != nil {
			return err
		}
		if _, authed := AuthenticatedAccountID(sess); !authed {
			return gateway.ErrEndSession
		}
		return nil
	}
}

const frontEndThemeAnsweredKey = "session.frontend_theme_answered"
