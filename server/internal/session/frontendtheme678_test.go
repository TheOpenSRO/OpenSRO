package session

import (
	"bufio"
	"context"
	"encoding/binary"
	"net"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
)

// Round 678: the operator's front-end theme (OURS). Every name the client
// resolves inside a fixed folder of its own; nothing the operator types may
// step out of that folder.

func TestFrontEndThemeIntroValidation(t *testing.T) {
	for _, tc := range []struct {
		in, want string
		warn     bool
		info     bool // a valid name the client may not find
	}{
		{in: "", want: ""},
		{in: "roc", want: "roc"},
		{in: "china_whatf", want: "china_whatf"},
		{in: "jupiter_login", want: "jupiter_login"},
		{in: "  egypt\n", want: "egypt"},
		{in: "ROC", want: "ROC"},
		{in: "my-server_intro2", want: "my-server_intro2", info: true},
		{in: `script\intro\roc.txt`, want: `script\intro\roc.txt`},
		{in: `SCRIPT\Intro\ruby_baghdad.TXT`, want: `SCRIPT\Intro\ruby_baghdad.TXT`},
		{in: `script\intro\my intro.txt`, want: `script\intro\my intro.txt`, info: true},
		{in: strings.Repeat("a", 64), want: strings.Repeat("a", 64), info: true},
		// Everything below must be refused.
		{in: strings.Repeat("a", 65), warn: true},
		{in: "../x", warn: true},
		{in: `..\x`, warn: true},
		{in: "..", warn: true},
		{in: `C:\x`, warn: true},
		{in: "C:x", warn: true},
		{in: "/etc/passwd", warn: true},
		{in: `\\host\share\x`, warn: true},
		{in: `script\intro\..\x.txt`, warn: true},
		{in: `script\intro\..\..\x.txt`, warn: true},
		{in: `script\intro\sub\x.txt`, warn: true},
		{in: `script/intro/roc.txt`, warn: true},
		{in: `script\intro\roc.txt\..`, warn: true},
		{in: `script\intro\.txt`, warn: true},
		{in: `script\intro\roc.ogg`, warn: true},
		{in: "roc.txt", warn: true},
		{in: "ro\x00c", warn: true},
		{in: "ro\x1bc", warn: true},
		{in: "ro c", warn: true},
		{in: "ròc", warn: true},
	} {
		got, warnings, infos := NewFrontEndTheme(FrontEndTheme{Intro: tc.in})
		if got.Intro != tc.want {
			t.Errorf("intro %q: served %q, want %q", tc.in, got.Intro, tc.want)
		}
		if (len(warnings) > 0) != tc.warn {
			t.Errorf("intro %q: warnings %q, want a warning: %v", tc.in, warnings, tc.warn)
		}
		if (len(infos) > 0) != tc.info {
			t.Errorf("intro %q: infos %q, want an info: %v", tc.in, infos, tc.info)
		}
		if tc.warn && len(warnings) > 0 && !strings.Contains(warnings[0], strconv.Quote(tc.in)) {
			t.Errorf("intro %q: the warning %q does not name the value", tc.in, warnings[0])
		}
		if tc.info && len(infos) > 0 && !strings.Contains(infos[0], "option.txt's IntroName") {
			t.Errorf("intro %q: the info %q does not say what the client falls back to", tc.in, infos[0])
		}
	}
	// The custom-intro line names the folder the client looks in.
	_, _, infos := NewFrontEndTheme(FrontEndTheme{Intro: "myintro"})
	if len(infos) != 1 || !strings.Contains(infos[0], "custom/intro/myintro.txt") {
		t.Errorf("custom intro info %q does not name custom/intro/myintro.txt", infos)
	}
}

func TestFrontEndThemeBGMAndImageValidation(t *testing.T) {
	for _, tc := range []struct {
		in   string
		ok   bool
		logo bool // an image: checked as the logo and both band arts
	}{
		{in: "maintheme_cut.ogg", ok: true},
		{in: "Title Theme-2.OGG", ok: true},
		{in: "intro.wav"},
		{in: "intro.v2.mp3"}, {in: "intro.v2.ogg", ok: true},
		{in: "../maintheme.ogg"},
		{in: "a..b.ogg"},
		{in: `..\maintheme.ogg`},
		{in: "/etc/passwd"},
		{in: `C:\music\x.ogg`},
		{in: "x.ogg/"},
		{in: "maintheme.flac"},
		{in: "maintheme"},
		{in: strings.Repeat("a", 65) + ".ogg"},
		{in: "x\x00.ogg"},

		{in: "mylogo.png", ok: true, logo: true},
		{in: "My-Logo_2.DDJ", ok: true, logo: true},
		{in: strings.Repeat("l", 64) + ".png", ok: true, logo: true},
		{in: strings.Repeat("l", 65) + ".png", logo: true},
		{in: "../mylogo.png", logo: true},
		{in: `..\mylogo.png`, logo: true},
		{in: "my logo.png", logo: true},
		{in: "my.logo.png", logo: true},
		{in: "/etc/logo.png", logo: true},
		{in: `C:\logo.png`, logo: true},
		{in: "logo.jpg", logo: true},
		{in: "logo.png\x00", logo: true},
	} {
		want := ""
		if tc.ok {
			want = tc.in
		}
		if !tc.logo {
			theme, warnings, _ := NewFrontEndTheme(FrontEndTheme{BGM: tc.in})
			if theme.BGM != want || (len(warnings) > 0) == tc.ok {
				t.Errorf("bgm %q: served %q with warnings %q, want %q", tc.in, theme.BGM, warnings, want)
			}
			continue
		}
		for _, field := range []struct {
			key string
			set func(*FrontEndTheme) *string
		}{
			{"logo", func(t *FrontEndTheme) *string { return &t.Logo }},
			{"band_top", func(t *FrontEndTheme) *string { return &t.BandTop }},
			{"band_bottom", func(t *FrontEndTheme) *string { return &t.BandBottom }},
		} {
			var raw FrontEndTheme
			*field.set(&raw) = tc.in
			theme, warnings, _ := NewFrontEndTheme(raw)
			if got := *field.set(&theme); got != want || (len(warnings) > 0) == tc.ok {
				t.Errorf("%s %q: served %q with warnings %q, want %q", field.key, tc.in, got, warnings, want)
			}
			if len(warnings) > 0 && (!strings.Contains(warnings[0], field.key) || !strings.Contains(warnings[0], strconv.Quote(tc.in))) {
				t.Errorf("%s %q: the warning %q does not name the setting and value", field.key, tc.in, warnings[0])
			}
		}
	}
}

func TestFrontEndThemeCopyright(t *testing.T) {
	theme, warnings, _ := NewFrontEndTheme(FrontEndTheme{Copyright: "  (c) 2026 My Server <ours> & co  \n"})
	if theme.Copyright != "(c) 2026 My Server <ours> & co" || len(warnings) != 0 {
		t.Errorf("plain copyright: %q, warnings %q", theme.Copyright, warnings)
	}
	theme, warnings, _ = NewFrontEndTheme(FrontEndTheme{Copyright: "line\none\ttab\x7f\x1b[31mred\x00"})
	if theme.Copyright != "lineonetab[31mred" || len(warnings) != 1 {
		t.Errorf("control characters: %q, warnings %q", theme.Copyright, warnings)
	}
	theme, _, _ = NewFrontEndTheme(FrontEndTheme{Copyright: "bad\xffutf8"})
	if theme.Copyright != "badutf8" {
		t.Errorf("invalid UTF-8: %q", theme.Copyright)
	}
	long := strings.Repeat("é", 250)
	theme, warnings, _ = NewFrontEndTheme(FrontEndTheme{Copyright: long})
	if n := len([]rune(theme.Copyright)); n != FrontEndCopyrightMaxRunes || len(warnings) != 1 || !strings.Contains(warnings[0], "truncated") {
		t.Errorf("overlong copyright: %d runes, warnings %q", n, warnings)
	}
	exact := strings.Repeat("x", FrontEndCopyrightMaxRunes)
	theme, warnings, _ = NewFrontEndTheme(FrontEndTheme{Copyright: exact})
	if theme.Copyright != exact || len(warnings) != 0 {
		t.Errorf("200-character copyright changed: %d runes, warnings %q", len(theme.Copyright), warnings)
	}
}

func TestFrontEndThemeEncodeExactJSON(t *testing.T) {
	for _, tc := range []struct {
		theme FrontEndTheme
		json  string
	}{
		{FrontEndTheme{}, `{"v":1,"intro":"","bgm":"","logo":"","copyright":"","band_top":"","band_bottom":"","charselect":null,"create":null}`},
		{FrontEndTheme{Intro: "roc", BGM: "maintheme_cut.ogg", Logo: "mylogo.png", Copyright: `(c) "Ours" <x> & é`, BandTop: "top.png", BandBottom: "bottom.ddj"},
			`{"v":1,"intro":"roc","bgm":"maintheme_cut.ogg","logo":"mylogo.png","copyright":"(c) \"Ours\" <x> & é","band_top":"top.png","band_bottom":"bottom.ddj","charselect":null,"create":null}`},
		{FrontEndTheme{Intro: `script\intro\egypt.txt`},
			`{"v":1,"intro":"script\\intro\\egypt.txt","bgm":"","logo":"","copyright":"","band_top":"","band_bottom":"","charselect":null,"create":null}`},
		// A theme built by hand, not through NewFrontEndTheme: its unsafe
		// names still never reach the wire.
		{FrontEndTheme{Intro: "../../etc/passwd", BGM: "../x.ogg", Logo: `C:\x.png`, Copyright: "ok\x00", BandTop: "../t.png", BandBottom: `..\b.png`},
			`{"v":1,"intro":"","bgm":"","logo":"","copyright":"ok","band_top":"","band_bottom":"","charselect":null,"create":null}`},
	} {
		payload := tc.theme.Encode()
		if n := int(binary.LittleEndian.Uint16(payload)); n != len(payload)-2 {
			t.Errorf("%+v: length prefix %d, %d bytes follow", tc.theme, n, len(payload)-2)
		}
		if got := string(payload[2:]); got != tc.json {
			t.Errorf("%+v:\n got %s\nwant %s", tc.theme, got, tc.json)
		}
		back, err := DecodeFrontEndTheme(payload)
		if err != nil {
			t.Fatalf("%+v: DecodeFrontEndTheme: %v", tc.theme, err)
		}
		want, _, _ := NewFrontEndTheme(tc.theme)
		if back != want {
			t.Errorf("round trip: got %+v, want %+v", back, want)
		}
	}
}

func TestDecodeFrontEndThemeIsStrict(t *testing.T) {
	frame := func(j string) []byte {
		out := binary.LittleEndian.AppendUint16(nil, uint16(len(j)))
		return append(out, j...)
	}
	good := `{"v":1,"intro":"","bgm":"","logo":"","copyright":"","band_top":"","band_bottom":"","charselect":null,"create":null}`
	if _, err := DecodeFrontEndTheme(frame(good)); err != nil {
		t.Fatalf("good payload refused: %v", err)
	}
	for name, data := range map[string][]byte{
		"empty":         nil,
		"one byte":      {0x01},
		"short":         frame(good)[:len(good)],
		"trailing byte": append(frame(good), 0),
		"version 2":     frame(strings.Replace(good, `"v":1`, `"v":2`, 1)),
		"no version":    frame(strings.Replace(good, `"v":1,`, ``, 1)),
		"extra key":     frame(strings.Replace(good, `"v":1,`, `"v":1,"x":0,`, 1)),
		"charselect":    frame(strings.Replace(good, `"charselect":null`, `"charselect":{}`, 1)),
		"create":        frame(strings.Replace(good, `"create":null`, `"create":[]`, 1)),
	} {
		if _, err := DecodeFrontEndTheme(data); err == nil {
			t.Errorf("%s: decoded without an error", name)
		}
	}
}

// startThemeServer serves handle on a real gateway.Server at a free port.
func startThemeServer(t *testing.T, handle gateway.Handler) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	ln.Close()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	srv := &gateway.Server{Addr: addr, Handle: handle}
	go srv.ListenAndServe(ctx)
	return addr
}

func dialTheme(t *testing.T, addr string) net.Conn {
	t.Helper()
	var conn net.Conn
	var err error
	for i := 0; i < 50; i++ {
		if conn, err = net.DialTimeout("tcp", addr, 100*time.Millisecond); err == nil {
			t.Cleanup(func() { conn.Close() })
			return conn
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("dial %s: %v", addr, err)
	return nil
}

// On a fresh connection that has sent nothing else, OpFrontEndThemeRequest
// (with or without stray payload bytes) is answered with OpFrontEndTheme; no
// other opcode is; and the session is not logged in by asking.
func TestFrontEndThemeHandlerOnAFreshSession(t *testing.T) {
	theme, _, _ := NewFrontEndTheme(FrontEndTheme{Intro: "roc", BGM: "maintheme_cut.ogg", Logo: "mylogo.png",
		Copyright: "(c) 2026 Ours", BandTop: "top.png", BandBottom: "bottom.png"})
	authed := make(chan bool, 16)
	probe := func(_ context.Context, sess *gateway.Session, p *proto.Packet) error {
		_, ok := AuthenticatedAccountID(sess)
		authed <- ok
		return nil
	}
	addr := startThemeServer(t, gateway.Chain(FrontEndThemeHandler(theme), LoginHandler(account.NewMemStore()), probe))
	conn := dialTheme(t, addr)
	r := bufio.NewReader(conn)

	// Opcodes that are not the request get nothing from the theme handler.
	for _, op := range []uint16{OpFrontEndTheme, 0x0007, 0x7001} {
		if err := proto.Write(conn, &proto.Packet{Opcode: op, Data: []byte{1, 2, 3}}, nil, nil); err != nil {
			t.Fatal(err)
		}
	}
	if err := proto.Write(conn, &proto.Packet{Opcode: OpFrontEndThemeRequest, Data: []byte{0xde, 0xad}}, nil, nil); err != nil {
		t.Fatal(err)
	}
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	p, err := proto.Read(r, nil, nil)
	if err != nil {
		t.Fatalf("no reply to OpFrontEndThemeRequest: %v", err)
	}
	if p.Opcode != OpFrontEndTheme {
		t.Fatalf("reply opcode %#04x, want OpFrontEndTheme %#04x (an earlier opcode was answered?)", p.Opcode, OpFrontEndTheme)
	}
	got, err := DecodeFrontEndTheme(p.Data)
	if err != nil {
		t.Fatal(err)
	}
	if got != theme {
		t.Errorf("served %+v, want %+v", got, theme)
	}
	// The three other opcodes went down the chain; the request did not.
	for i := 0; i < 3; i++ {
		select {
		case ok := <-authed:
			if ok {
				t.Errorf("packet %d: the session is authenticated after asking for the theme", i)
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("packet %d never reached the end of the chain", i)
		}
	}
	// Round 678's review: one answer per connection -- an unauthenticated
	// asker's connection is closed after it, with nothing more sent.
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	if p, err := proto.Read(r, nil, nil); err == nil {
		t.Errorf("unexpected extra frame opcode %#04x", p.Opcode)
	} else if ne, ok := err.(net.Error); ok && ne.Timeout() {
		t.Errorf("the connection stayed open after the answer (read timed out instead of ending)")
	}
}

// A logged-in session that asks gets one answer, and nothing for a repeat;
// its connection stays open (round 678's review).
func TestFrontEndThemeHandlerAnswersOncePerSession(t *testing.T) {
	theme, _, _ := NewFrontEndTheme(FrontEndTheme{Intro: "roc"})
	store := account.NewMemStore()
	if _, err := store.Add("someone", "secret"); err != nil {
		t.Fatal(err)
	}
	addr := startThemeServer(t, gateway.Chain(FrontEndThemeHandler(theme), LoginHandler(store)))
	conn := dialTheme(t, addr)
	r := bufio.NewReader(conn)
	read := func(what string) *proto.Packet {
		t.Helper()
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		p, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("%s: %v", what, err)
		}
		return p
	}
	login := &proto.Packet{Opcode: OpLogin, Data: (&LoginRequest{Username: "someone", Password: "secret"}).Encode()}
	if err := proto.Write(conn, login, nil, nil); err != nil {
		t.Fatal(err)
	}
	if p := read("login reply"); p.Opcode != OpLoginResult {
		t.Fatalf("login reply opcode %#04x", p.Opcode)
	}
	for i := 0; i < 3; i++ {
		if err := proto.Write(conn, &proto.Packet{Opcode: OpFrontEndThemeRequest}, nil, nil); err != nil {
			t.Fatal(err)
		}
	}
	if p := read("theme reply"); p.Opcode != OpFrontEndTheme {
		t.Fatalf("theme reply opcode %#04x", p.Opcode)
	}
	// The repeats get nothing, and the connection is still usable.
	if err := proto.Write(conn, login, nil, nil); err != nil {
		t.Fatal(err)
	}
	if p := read("the next reply"); p.Opcode != OpLoginResult {
		t.Fatalf("after the repeats the next frame is %#04x, want the second login's reply (a repeat was answered?)", p.Opcode)
	}
}

// The theme's two opcodes are new in round 678: no other opcode this package
// defines may share them.
func TestFrontEndThemeOpcodesAreUnique(t *testing.T) {
	for _, op := range []uint16{OpLogin, OpLoginResult, OpRegister, OpRegisterResult} {
		if op == OpFrontEndThemeRequest || op == OpFrontEndTheme {
			t.Errorf("opcode %#04x collides with the front-end theme", op)
		}
	}
	if OpFrontEndThemeRequest != 0x0005 || OpFrontEndTheme != 0x0006 {
		t.Errorf("front-end theme opcodes moved: %#04x/%#04x, the client sends 0x0005 and reads 0x0006", OpFrontEndThemeRequest, OpFrontEndTheme)
	}
}
