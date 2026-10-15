package retailgw

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// Round 788: the login past the list, RunLogin against the fake, and the
// transcripts the Godot client's RetailLogin replays byte for byte
// (client/scripts/frontend/retail_login_test.gd). Test values only.

const (
	testUser   = "Tester"
	testPass   = "pw12"
	testCode   = "1"
	testToken  = 0x01020304
	testAgentH = "10.0.0.5"
	testAgentP = 15884
)

// testImage is a 0x2322 blob in the writer's layout (READ: ImageTrans.dll's
// compress2 path; docs/protocol/opcodes/gateway.md): a synthetic 200 x 64
// picture whose pixel (x, y) is set when (x + 2y) % 16 < 3 or x == y, so
// the Godot suite can check the bit order. Test values only.
var testImage = func() []byte {
	b, err := EncodeCaptchaBlob(200, 64, func(x, y int) bool { return (x+2*y)%16 < 3 || x == y })
	if err != nil {
		panic(err)
	}
	return b
}()

// lobbyListHex is the lobby golden's two-character list (one file holds the
// lobby's bytes: client/scripts/net/testdata/lobby_golden.json).
func lobbyListHex(t *testing.T) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "..", "..", "client", "scripts", "net", "testdata", "lobby_golden.json"))
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Vectors []struct {
			Name string `json:"name"`
			Hex  string `json:"hex"`
		} `json:"vectors"`
	}
	if err := json.Unmarshal(b, &doc); err != nil {
		t.Fatal(err)
	}
	for _, v := range doc.Vectors {
		if strings.HasPrefix(v.Name, "list, two characters") {
			h := strings.NewReplacer(" ", "", "|", "").Replace(v.Hex)
			out, err := hex.DecodeString(h)
			if err != nil {
				t.Fatal(err)
			}
			return out
		}
	}
	t.Fatal("no two-character list in the lobby golden")
	return nil
}

type loginScenario struct {
	name      string
	login     LoginParams
	answers   []string // the image codes typed, in order
	fake      func(*FakeLogin)
	list      ShardList
	events    []string // the event kinds, in order
	wantLobby bool
}

func loginScenarios() []loginScenario {
	right := LoginParams{Username: testUser, Password: testPass, Shard: "Solo"}
	one := ShardList{Farms: []Farm{{ID: 1, Name: "F"}}, Shards: []Shard{{ID: 3, Name: "Solo", Current: 5, Capacity: 100, State: 1, Farm: 1}}}
	ts := []byte{0xea, 0x07, 0x0a, 0x00, 0x16, 0x00, 0x0d, 0x00, 0x05, 0x00, 0x09, 0x00, 0, 0, 0, 0}
	blocked := append([]byte{2, 2, 1, 7, 0}, "Botting"...)
	blocked = append(blocked, ts...)
	return []loginScenario{
		{name: "login_ok", login: right, answers: []string{testCode}, list: one,
			events: []string{"captcha", "captcha_ok", "login_ok", "agent_ok", "frame"}, wantLobby: true},
		{name: "shard_by_name", login: LoginParams{Username: testUser, Password: testPass, Shard: "Populated"}, answers: []string{testCode}, list: bandList,
			events: []string{"captcha", "captcha_ok", "login_ok", "agent_ok", "frame"}, wantLobby: true},
		{name: "captcha_retry", login: right, answers: []string{"7", testCode}, list: one,
			events: []string{"captcha", "captcha_failed", "captcha", "captcha_ok", "login_ok", "agent_ok", "frame"}, wantLobby: true},
		{name: "wrong_password", login: LoginParams{Username: testUser, Password: "nope", Shard: "Solo"}, list: one,
			events: []string{"login_failed"}},
		{name: "blocked", login: right, list: one, fake: func(f *FakeLogin) { f.Reply = blocked },
			events: []string{"login_failed"}},
		{name: "already_connected", login: right, list: one, fake: func(f *FakeLogin) { f.Reply = []byte{2, 3} },
			events: []string{"login_failed"}},
		{name: "agent_refused", login: right, answers: []string{testCode}, list: one, fake: func(f *FakeLogin) { f.AgentReply = []byte{2, 2} },
			events: []string{"captcha", "captcha_ok", "login_ok", "agent_failed"}},
	}
}

type loginRun struct {
	res   LoginResult
	err   error
	conns [][]event
}

func runLoginScenario(t *testing.T, sc loginScenario) loginRun {
	t.Helper()
	rec := &recorder{}
	fl := &FakeLogin{Username: testUser, Password: testPass, Captcha: testCode, Image: testImage,
		Token: testToken, AgentHost: testAgentH, AgentPort: testAgentP, Lobby: lobbyListHex(t)}
	if sc.fake != nil {
		sc.fake(fl)
	}
	srv, err := Listen("127.0.0.1:0", Config{List: sc.list, ContentID: testContentID, Version: testVersion,
		Fixed: testFixed, CRCSeeds: []uint32{0x00000007}, Record: rec.record, Logf: t.Logf, Login: fl})
	if err != nil {
		t.Fatal(err)
	}
	x := uint32(testPrivateX)
	res, rerr := RunLogin(context.Background(), srv.Addr(), LoginOptions{
		Info:  ClientInfo{ContentID: testContentID, Version: testVersion},
		Login: sc.login,
		Captcha: func(_ CaptchaImage, attempt int) string {
			if attempt-1 < len(sc.answers) {
				return sc.answers[attempt-1]
			}
			return ""
		},
		Agent:    srv.Addr(), // the agent is the fake's second connection
		PrivateX: &x,
	})
	_ = srv.Close()
	return loginRun{res: res, err: rerr, conns: rec.list()}
}

func kinds(ev []LoginEvent) []string {
	var out []string
	for _, e := range ev {
		out = append(out, e.Kind)
	}
	return out
}

// TestRunLogin: the Go client through the whole legacy login, every case the
// Godot client replays.
func TestRunLogin(t *testing.T) {
	for _, sc := range loginScenarios() {
		t.Run(sc.name, func(t *testing.T) {
			r := runLoginScenario(t, sc)
			if r.err != nil {
				t.Fatal(r.err)
			}
			if got := kinds(r.res.Events); !reflect.DeepEqual(got, sc.events) {
				t.Fatalf("events %v, want %v", got, sc.events)
			}
			if sc.wantLobby != (r.res.Lobby != nil) {
				t.Fatalf("lobby %x", r.res.Lobby)
			}
			for _, e := range r.res.Events {
				switch e.Kind {
				case "login_ok":
					if e.Reply.Token != testToken || e.Reply.AgentHost != testAgentH || e.Reply.AgentPort != testAgentP {
						t.Fatalf("0xA102 %+v", e.Reply)
					}
				case "captcha":
					if !bytes.Equal(e.Image.Blob, testImage) {
						t.Fatalf("image %x", e.Image.Blob)
					}
				case "captcha_failed":
					if e.Max != 3 || e.Used != 1 {
						t.Fatalf("0xA323 %d/%d", e.Max, e.Used)
					}
				}
			}
		})
	}
}

func TestLoginCodecs(t *testing.T) {
	if got := hex.EncodeToString(EncodeGatewayLogin(22, "Tester", "pw12", 64)); got != "16"+"0600546573746572"+"040070773132"+"4000" {
		t.Fatalf("0x6102 %s (the session golden's first vector)", got)
	}
	got := EncodeAgentLogin(1, "TeStEr", "pw", 22, [6]byte{1, 2, 3, 4, 5, 6})
	if hex.EncodeToString(got) != "01000000"+"0600746573746572"+"02007077"+"16"+"010203040506" {
		t.Fatalf("0x6103 %x", got)
	}
	if _, err := PickShard(bandList, "Nope"); err == nil {
		t.Fatal("no such shard among five")
	}
	if id, _ := PickShard(ShardList{Shards: []Shard{{ID: 9, Name: "X"}}}, "Nope"); id != 9 {
		t.Fatal("the only shard is taken when none matches")
	}
	if _, err := DecodeCaptchaImage([]byte{0, 3, 0, 1, 2}); err == nil {
		t.Fatal("a short image")
	}
	if r, err := DecodeLoginReply([]byte{1, 1, 0, 0, 0, 0, 0, 0, 0}); err != nil || !r.OK || r.Token != 1 {
		t.Fatalf("%+v %v", r, err)
	}
}

func loginTranscriptPath() string {
	return filepath.Join("..", "..", "..", "client", "scripts", "frontend", "testdata", "retail_login_transcripts.json")
}

type loginTranscript struct {
	Login       LoginParams `json:"login"`
	Answers     []string    `json:"answers,omitempty"`
	Events      []string    `json:"events"`
	Connections [][]event   `json:"connections"`
}

func buildLoginTranscripts(t *testing.T) []byte {
	out := struct {
		Note      string                     `json:"note"`
		ContentID int                        `json:"content_id"`
		Version   int                        `json:"version"`
		PrivateX  uint32                     `json:"private_x"`
		Token     uint32                     `json:"token"`
		Image     string                     `json:"image"`
		Scenarios map[string]loginTranscript `json:"scenarios"`
	}{
		Note:      "GENERATED by server/internal/retailgw TestLoginTranscripts (UPDATE_TRANSCRIPTS=1 rewrites it). Connection 0 is the gateway, 1 the agent. Test values only.",
		ContentID: testContentID, Version: testVersion, PrivateX: testPrivateX, Token: testToken,
		Image:     hex.EncodeToString(testImage),
		Scenarios: map[string]loginTranscript{},
	}
	for _, sc := range loginScenarios() {
		r := runLoginScenario(t, sc)
		if r.err != nil {
			t.Fatalf("%s: %v", sc.name, r.err)
		}
		out.Scenarios[sc.name] = loginTranscript{Login: sc.login, Answers: sc.answers, Events: kinds(r.res.Events), Connections: r.conns}
	}
	b, err := json.MarshalIndent(out, "", " ")
	if err != nil {
		t.Fatal(err)
	}
	return append(b, '\n')
}

// TestLoginTranscripts keeps the Godot client's login transcripts equal to
// what RunLogin and the fake exchange.
func TestLoginTranscripts(t *testing.T) {
	got := buildLoginTranscripts(t)
	if os.Getenv("UPDATE_TRANSCRIPTS") == "1" {
		if err := os.WriteFile(loginTranscriptPath(), got, 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	have, err := os.ReadFile(loginTranscriptPath())
	if err != nil {
		t.Fatalf("%v (UPDATE_TRANSCRIPTS=1 writes it)", err)
	}
	if !bytes.Equal(have, got) {
		t.Fatalf("%s is stale: run UPDATE_TRANSCRIPTS=1 go test ./internal/retailgw -run TestLoginTranscripts", loginTranscriptPath())
	}
}
