package retailgw

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/proto"
)

// Test values only (not claims about any real archive or server).
const (
	testContentID = 22
	testVersion   = 188
	testPrivateX  = 0x07654321
)

var testFixed = &Fixed{
	BlowfishKey:  [8]byte{0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88},
	CountSeed:    0x12345678,
	HandshakeKey: [8]byte{0xa1, 0xb2, 0xc3, 0xd4, 0xe5, 0xf6, 0x07, 0x18},
	G:            2147483629, // primes, the smaller as G (READ 0x4c6fc0)
	P:            2147483647,
	Y:            0x01234567,
}

// bandList has one shard per band of round 679's list (thresholds 35 / 97).
var bandList = ShardList{
	Farms: []Farm{{ID: 1, Name: "Farm1"}},
	Shards: []Shard{
		{ID: 64, Name: "Check", Current: 10, Capacity: 1000, State: 0, Farm: 1},
		{ID: 65, Name: "Easy", Current: 349, Capacity: 1000, State: 1, Farm: 1},
		{ID: 66, Name: "Populated", Current: 350, Capacity: 1000, State: 1, Farm: 1},
		{ID: 67, Name: "Crowded", Current: 970, Capacity: 1000, State: 1, Farm: 1},
		{ID: 68, Name: "Full", Current: 1000, Capacity: 1000, State: 1, Farm: 1},
	},
}

type scenario struct {
	name    string
	cfg     Config
	timeout time.Duration
	wantErr string // a substring; "" = the list arrives
	want    ShardList
	conns   int // connections the probe makes
}

func scenarios() []scenario {
	one := ShardList{Farms: []Farm{{ID: 1, Name: "F"}}, Shards: []Shard{{ID: 3, Name: "Solo", Current: 5, Capacity: 100, State: 1, Farm: 1}}}
	base := func() Config {
		return Config{List: bandList, ContentID: testContentID, Version: testVersion, Fixed: testFixed, CRCSeeds: []uint32{0x00000007}}
	}
	with := func(f func(*Config)) Config {
		c := base()
		f(&c)
		return c
	}
	return []scenario{
		{name: "bands", cfg: base(), want: bandList, conns: 1},
		{name: "single_shard", cfg: with(func(c *Config) { c.List = one }), want: one, conns: 1},
		{name: "no_farm_byte", cfg: with(func(c *Config) { c.ContentID = 0; c.Version = 0 }), want: stripFarm(bandList), conns: 1},
		{name: "plain_patch_reply", cfg: with(func(c *Config) { c.PlainPatchReply = true }), want: bandList, conns: 1},
		{name: "encrypted_list", cfg: with(func(c *Config) { c.EncryptList = true }), want: bandList, conns: 1},
		{name: "no_key_exchange", cfg: with(func(c *Config) { c.Flags = 0x06 }), want: bandList, conns: 1},
		{name: "unknown_crc_index_reconnects", cfg: with(func(c *Config) { c.CRCSeeds = []uint32{18, 7} }), want: bandList, conns: 2},
		{name: "crc_seed_zero_is_index_1", cfg: with(func(c *Config) { c.CRCSeeds = []uint32{0x100} }), want: bandList, conns: 1},
		{name: "refused", cfg: with(func(c *Config) { c.Refuse = 4 }), wantErr: "not in service", conns: 1},
		{name: "wrong_version", cfg: with(func(c *Config) { c.Version = 189 }), wantErr: "result 2, code 2", conns: 1},
		{name: "stall_after_hello", cfg: with(func(c *Config) { c.Fault = FaultStallAfterHello }), timeout: 700 * time.Millisecond, wantErr: "connection ended", conns: 1},
		{name: "bad_signature", cfg: with(func(c *Config) { c.Fault = FaultBadSignature }), wantErr: "challenge does not match", conns: 1},
		{name: "check_byte", cfg: with(func(c *Config) { c.Fault = FaultCheckByte }), wantErr: "check byte 0x5a", conns: 1},
		{name: "truncated_list", cfg: with(func(c *Config) { c.Fault = FaultTruncatedList }), wantErr: "0xA101", conns: 1},
		{name: "malformed_list", cfg: with(func(c *Config) { c.Fault = FaultMalformedList }), wantErr: "is 7, not 0 or 1", conns: 1},
		{name: "truncated_frame", cfg: with(func(c *Config) { c.Fault = FaultTruncatedFrame }), wantErr: "connection ended", conns: 1},
		{name: "oversize_frame", cfg: with(func(c *Config) { c.Fault = FaultOversizeFrame }), wantErr: "is over 4096", conns: 1},
		{name: "not_gateway", cfg: with(func(c *Config) { c.Fault = FaultNotGateway }), wantErr: "AgentServer", conns: 1},
		{name: "flood", cfg: with(func(c *Config) { c.Fault = FaultFlood }), wantErr: "more than 64 frames", conns: 1},
		{name: "flood_bytes", cfg: with(func(c *Config) { c.Fault = FaultFloodBytes }), wantErr: "more than 65536 bytes", conns: 1},
	}
}

func stripFarm(l ShardList) ShardList {
	out := ShardList{Farms: l.Farms}
	for _, s := range l.Shards {
		s.Farm = 0
		out.Shards = append(out.Shards, s)
	}
	return out
}

type event struct {
	S      string `json:"s,omitempty"`
	C      string `json:"c,omitempty"`
	Repeat int    `json:"repeat,omitempty"`
	Close  bool   `json:"close,omitempty"`
}

type recorder struct {
	mu    sync.Mutex
	conns map[int][]event
}

func (r *recorder) record(conn int, fromServer bool, b []byte) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.conns == nil {
		r.conns = map[int][]event{}
	}
	ev := r.conns[conn]
	if b == nil {
		r.conns[conn] = append(ev, event{Close: true})
		return
	}
	h := hex.EncodeToString(b)
	if fromServer {
		if n := len(ev); n > 0 && ev[n-1].S == h {
			if ev[n-1].Repeat == 0 {
				ev[n-1].Repeat = 1
			}
			ev[n-1].Repeat++
			r.conns[conn] = ev
			return
		}
		r.conns[conn] = append(ev, event{S: h})
		return
	}
	r.conns[conn] = append(ev, event{C: h})
}

func (r *recorder) list() [][]event {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([][]event, len(r.conns))
	for i := range out {
		out[i] = r.conns[i]
	}
	return out
}

func runScenario(t *testing.T, sc scenario) (ShardList, error, [][]event) {
	t.Helper()
	rec := &recorder{}
	cfg := sc.cfg
	cfg.Record = rec.record
	cfg.Logf = t.Logf
	srv, err := Listen("127.0.0.1:0", cfg)
	if err != nil {
		t.Fatal(err)
	}
	x := uint32(testPrivateX)
	opt := DefaultProbeOptions(ClientInfo{ContentID: testContentID, Version: testVersion})
	opt.PrivateX = &x
	if sc.timeout > 0 {
		opt.Budget = sc.timeout
	}
	l, perr := Probe(context.Background(), srv.Addr(), opt)
	_ = srv.Close()
	if got := srv.Connections(); got != sc.conns {
		t.Errorf("%s: %d connections, want %d", sc.name, got, sc.conns)
	}
	return l, perr, rec.list()
}

// TestProbeScenarios: the Go client against the fake gateway, every case the
// Godot client is tested on.
func TestProbeScenarios(t *testing.T) {
	for _, sc := range scenarios() {
		t.Run(sc.name, func(t *testing.T) {
			l, err, _ := runScenario(t, sc)
			if sc.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), sc.wantErr) {
					t.Fatalf("error %v, want one containing %q", err, sc.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(l, sc.want) {
				t.Fatalf("list %+v, want %+v", l, sc.want)
			}
		})
	}
}

// TestProbeRandomHandshake: the fake's random primes, keys and seeds (the
// retail behaviour), many times.
func TestProbeRandomHandshake(t *testing.T) {
	srv, err := Listen("127.0.0.1:0", Config{List: bandList, ContentID: testContentID, Logf: t.Logf})
	if err != nil {
		t.Fatal(err)
	}
	defer srv.Close()
	for i := range 40 {
		l, err := Probe(context.Background(), srv.Addr(), DefaultProbeOptions(ClientInfo{ContentID: testContentID, Version: testVersion}))
		if err != nil {
			t.Fatalf("probe %d: %v", i, err)
		}
		if !reflect.DeepEqual(l, bandList) {
			t.Fatalf("probe %d: %+v", i, l)
		}
	}
}

// TestFakeChecksClientSecurity: the fake drops a client whose count or check
// byte is wrong (the gateway's 0x800b / 0x800c).
func TestFakeChecksClientSecurity(t *testing.T) {
	sec := &proto.RetailSecurity{Flags: 0x04, Count: proto.CountSeeds(5)}
	sec.CRC, _ = proto.CRCTable(7)
	other := &proto.RetailSecurity{Flags: 0x04, Count: sec.Count}
	f, _ := sec.EncodeClientFrame(0x6101, nil, false)
	rf, _ := proto.DecodeRetailFrame(f, other)
	other.CRC, _ = proto.CRCTable(7)
	if err := other.CheckFromClient(rf); err != nil {
		t.Fatalf("a good frame: %v", err)
	}
	bad := append([]byte(nil), f...)
	bad[5] ^= 1
	sec2 := &proto.RetailSecurity{Flags: 0x04, Count: proto.CountSeeds(5)}
	sec2.CRC, _ = proto.CRCTable(7)
	rf, _ = proto.DecodeRetailFrame(bad, sec2)
	if err := sec2.CheckFromClient(rf); err == nil || !strings.Contains(err.Error(), "0x800c") {
		t.Fatalf("a wrong check byte: %v", err)
	}
	sec3 := &proto.RetailSecurity{Flags: 0x04, Count: proto.CountSeeds(6)}
	sec3.CRC, _ = proto.CRCTable(7)
	rf, _ = proto.DecodeRetailFrame(f, sec3)
	if err := sec3.CheckFromClient(rf); err == nil || !strings.Contains(err.Error(), "0x800b") {
		t.Fatalf("a wrong count byte: %v", err)
	}
}

func TestShardListRoundTrip(t *testing.T) {
	for _, farm := range []bool{true, false} {
		p := EncodeShardList(bandList, farm)
		l, err := DecodeShardList(p, farm)
		want := bandList
		if !farm {
			want = stripFarm(bandList)
		}
		if err != nil || !reflect.DeepEqual(l, want) {
			t.Fatalf("farm=%v: %+v %v", farm, l, err)
		}
	}
	// The wrong layout is rejected, and DecodeShardListFor falls back.
	p := EncodeShardList(bandList, false)
	if _, err := DecodeShardList(p, true); err == nil {
		t.Fatal("a list without farm bytes read as one with them")
	}
	if l, farm, err := DecodeShardListFor(p, 22); err != nil || farm || len(l.Shards) != 5 {
		t.Fatalf("fallback: %v %v %v", l, farm, err)
	}
	// Exact bytes of a one-shard list with the farm byte.
	got := EncodeShardList(ShardList{Farms: []Farm{{1, "F"}}, Shards: []Shard{{ID: 3, Name: "Ab", Current: 5, Capacity: 100, State: 1, Farm: 1}}}, true)
	want := []byte{1, 1, 1, 0, 'F', 0, 1, 3, 0, 2, 0, 'A', 'b', 5, 0, 100, 0, 1, 1, 0}
	if !bytes.Equal(got, want) {
		t.Fatalf("% x\nwant % x", got, want)
	}
	for _, cid := range []byte{3, 5, 9, 10, 0x15, 0x16, 0x17, 0x1a, 0x1c, 0x22} {
		if !FarmByteFor(cid) {
			t.Errorf("content id %d: the gateway appends the farm byte", cid)
		}
	}
	for _, cid := range []byte{0, 1, 2, 4, 6, 18, 0x18} {
		if FarmByteFor(cid) {
			t.Errorf("content id %d: no farm byte", cid)
		}
	}
}

func TestMassive(t *testing.T) {
	parts := MassiveParts(OpPatchReply, []byte{1, 2, 3, 4, 5}, 2)
	if !bytes.Equal(parts[0], []byte{1, 3, 0, 0x00, 0xa1}) {
		t.Fatalf("header % x", parts[0])
	}
	var m Massive
	var op uint16
	var data []byte
	var done bool
	for _, p := range parts {
		var err error
		op, data, done, err = m.Feed(p)
		if err != nil {
			t.Fatal(err)
		}
	}
	if !done || op != OpPatchReply || !bytes.Equal(data, []byte{1, 2, 3, 4, 5}) {
		t.Fatalf("%v %x % x", done, op, data)
	}
	var m2 Massive
	if _, _, _, err := m2.Feed([]byte{0, 1}); err == nil {
		t.Fatal("a part before its header")
	}
	if _, _, _, err := m2.Feed([]byte{1, 99, 0, 0, 0xa1}); err == nil {
		t.Fatal("99 parts")
	}
}

func TestServerHelloStrict(t *testing.T) {
	h := ServerHello{Flags: 0x0e, CountSeed: 1, CRCSeed: 2, G: 3, P: 5, A: 4}
	p := h.Encode()
	if len(p) != 1+8+8+20 {
		t.Fatalf("a 0x0e hello is %d bytes", len(p))
	}
	if got, err := DecodeServerHello(p); err != nil || got != h {
		t.Fatalf("%+v %v", got, err)
	}
	if _, err := DecodeServerHello(append(p, 0)); err == nil {
		t.Fatal("a trailing byte")
	}
	if _, err := DecodeServerHello(p[:20]); err == nil {
		t.Fatal("a short hello")
	}
}

// transcriptPath is the Godot client's copy (client/scripts/frontend/testdata).
func transcriptPath() string {
	return filepath.Join("..", "..", "..", "client", "scripts", "frontend", "testdata", "retail_gateway_transcripts.json")
}

type transcriptFile struct {
	Note      string                        `json:"note"`
	ContentID int                           `json:"content_id"`
	Version   int                           `json:"version"`
	PrivateX  uint32                        `json:"private_x"`
	Scenarios map[string]transcriptScenario `json:"scenarios"`
	Vectors   map[string]any                `json:"vectors"`
}

type transcriptScenario struct {
	Error       string    `json:"error,omitempty"`
	TimeoutMs   int       `json:"timeout_ms,omitempty"`
	Shards      []Shard   `json:"shards,omitempty"`
	Connections [][]event `json:"connections"`
}

func buildTranscripts(t *testing.T) []byte {
	tf := transcriptFile{
		Note:      "GENERATED by server/internal/retailgw TestClientTranscripts (UPDATE_TRANSCRIPTS=1 rewrites it). Test values only.",
		ContentID: testContentID, Version: testVersion, PrivateX: testPrivateX,
		Scenarios: map[string]transcriptScenario{},
		Vectors:   vectors(),
	}
	for _, sc := range scenarios() {
		l, err, conns := runScenario(t, sc)
		ts := transcriptScenario{Connections: conns}
		if sc.wantErr != "" {
			if err == nil {
				t.Fatalf("%s: no error", sc.name)
			}
			ts.Error = sc.wantErr
		} else {
			if err != nil {
				t.Fatalf("%s: %v", sc.name, err)
			}
			ts.Shards = l.Shards
		}
		ts.TimeoutMs = int(sc.timeout / time.Millisecond)
		tf.Scenarios[sc.name] = ts
	}
	b, err := json.MarshalIndent(tf, "", " ")
	if err != nil {
		t.Fatal(err)
	}
	return append(b, '\n')
}

// TestClientTranscripts keeps the Godot client's transcripts equal to what
// the Go client and the fake gateway exchange.
func TestClientTranscripts(t *testing.T) {
	got := buildTranscripts(t)
	if os.Getenv("UPDATE_TRANSCRIPTS") == "1" {
		if err := os.WriteFile(transcriptPath(), got, 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	have, err := os.ReadFile(transcriptPath())
	if err != nil {
		t.Fatalf("%v (UPDATE_TRANSCRIPTS=1 writes it)", err)
	}
	if !bytes.Equal(have, got) {
		t.Fatalf("%s is stale: run UPDATE_TRANSCRIPTS=1 go test ./internal/retailgw -run TestClientTranscripts", transcriptPath())
	}
}

// vectors are byte-level known answers for the Godot client's primitives.
func vectors() map[string]any {
	v := map[string]any{}
	cs := proto.CountSeeds(0x12345678)
	v["count_seeds_12345678"] = hex.EncodeToString(cs[:])
	cs0 := proto.CountSeeds(0)
	v["count_seeds_0"] = hex.EncodeToString(cs0[:])
	st := cs
	var rolls []byte
	for range 6 {
		rolls = append(rolls, proto.NextCountByte(&st))
	}
	v["count_bytes_12345678"] = hex.EncodeToString(rolls)
	frame := []byte{0x00, 0x00, 0x01, 0x61, 0x00, 0x00}
	var checks []int
	for _, idx := range []byte{1, 7, 100, 239} {
		tab, _ := proto.CRCTable(idx)
		checks = append(checks, int(proto.CheckByte(tab, frame)))
	}
	v["check_6101_idx_1_7_100_239"] = checks
	tr := proto.KeyTransform([8]byte{1, 2, 3, 4, 5, 6, 7, 8}, 0xdeadbeef, 5)
	v["transform_0102030405060708_deadbeef_5"] = hex.EncodeToString(tr[:])
	v["modpow_2147483629_7654321_2147483647"] = proto.ModPow(2147483629, 0x07654321, 2147483647)
	c, _ := proto.NewRetailCipher([]byte{0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88})
	v["blowfish_le_1122334455667788_0001020304050607"] = hex.EncodeToString(c.Encrypt([]byte{0, 1, 2, 3, 4, 5, 6, 7}))
	var ints []int
	for i := 1; i < 256; i++ {
		if !proto.CRCIndexKnown(byte(i)) {
			ints = append(ints, i)
		}
	}
	v["unknown_crc_indices"] = ints
	return v
}

func TestProbeErrRetryIsReturnedAfterMaxAttempts(t *testing.T) {
	srv, err := Listen("127.0.0.1:0", Config{List: bandList, CRCSeeds: []uint32{18}, Logf: t.Logf})
	if err != nil {
		t.Fatal(err)
	}
	defer srv.Close()
	_, err = Probe(context.Background(), srv.Addr(), DefaultProbeOptions(ClientInfo{ContentID: testContentID}))
	if !errors.Is(err, ErrRetry) || srv.Connections() != 3 {
		t.Fatalf("%v after %d connections", err, srv.Connections())
	}
}
