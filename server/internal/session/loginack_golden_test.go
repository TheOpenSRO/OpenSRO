package session

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

// loginGoldenPath is the vector file client/scripts/net/login_ack_test.gd
// reads too: both sides encode the same fields to the same bytes and decode
// the same bytes to the same fields.
func loginGoldenPath() string {
	return filepath.Join("..", "..", "..", "client", "scripts", "net", "testdata", "login_golden.json")
}

type loginGoldenRequest struct {
	Name   string `json:"name"`
	Error  bool   `json:"error"`
	Hex    string `json:"hex"`
	Fields struct {
		ContentID uint8  `json:"content_id"`
		Username  string `json:"username"`
		Password  string `json:"password"`
		ShardID   uint16 `json:"shard_id"`
	} `json:"fields"`
}

type loginGoldenAck struct {
	Name   string `json:"name"`
	Error  bool   `json:"error"`
	Hex    string `json:"hex"`
	Fields struct {
		OK           bool   `json:"ok"`
		Token        uint32 `json:"token"`
		AgentHost    string `json:"agent_host"`
		AgentPort    uint16 `json:"agent_port"`
		Code         uint8  `json:"code"`
		MaxAttempts  uint32 `json:"max_attempts"`
		UsedAttempts uint32 `json:"used_attempts"`
		BlockKind    uint8  `json:"block_kind"`
		BlockReason  string `json:"block_reason"`
		BlockEnd     string `json:"block_end"`
	} `json:"fields"`
}

func TestLoginGolden(t *testing.T) {
	raw, err := os.ReadFile(loginGoldenPath())
	if err != nil {
		t.Fatal(err)
	}
	var file struct {
		Opcodes  map[string]uint16    `json:"opcodes"`
		Requests []loginGoldenRequest `json:"requests"`
		Acks     []loginGoldenAck     `json:"acks"`
	}
	if err := json.Unmarshal(raw, &file); err != nil {
		t.Fatal(err)
	}
	if file.Opcodes["gateway_login"] != OpGatewayLogin || file.Opcodes["gateway_login_ack"] != OpGatewayLoginAck {
		t.Fatalf("opcodes %v disagree with 0x%04x/0x%04x", file.Opcodes, OpGatewayLogin, OpGatewayLoginAck)
	}
	for _, v := range file.Requests {
		b := goldenBytes(t, v.Hex)
		got, err := DecodeGatewayLoginRequest(b)
		if v.Error {
			if err == nil {
				t.Errorf("%s: decoded %+v, want an error", v.Name, got)
			}
			continue
		}
		want := &GatewayLoginRequest{ContentID: v.Fields.ContentID, Username: v.Fields.Username,
			Password: v.Fields.Password, ShardID: v.Fields.ShardID}
		if err != nil || !reflect.DeepEqual(got, want) {
			t.Errorf("%s: decode = %+v, %v; want %+v", v.Name, got, err, want)
		}
		if enc := want.Encode(); !reflect.DeepEqual(enc, b) {
			t.Errorf("%s: encode = %x, want %x", v.Name, enc, b)
		}
	}
	for _, v := range file.Acks {
		b := goldenBytes(t, v.Hex)
		got, err := DecodeLoginAck(b)
		if v.Error {
			if err == nil {
				t.Errorf("%s: decoded %+v, want an error", v.Name, got)
			}
			continue
		}
		f := v.Fields
		want := &LoginAck{OK: f.OK, Token: f.Token, AgentHost: f.AgentHost, AgentPort: f.AgentPort,
			Code: f.Code, MaxAttempts: f.MaxAttempts, UsedAttempts: f.UsedAttempts,
			BlockKind: f.BlockKind, BlockReason: f.BlockReason}
		if f.BlockEnd != "" {
			end, perr := time.Parse("2006-01-02 15:04:05", f.BlockEnd)
			if perr != nil {
				t.Fatalf("%s: block_end: %v", v.Name, perr)
			}
			want.BlockEnd = end
		}
		if err != nil || !reflect.DeepEqual(got, want) {
			t.Errorf("%s: decode = %+v, %v; want %+v", v.Name, got, err, want)
		}
		if enc := want.Encode(); !reflect.DeepEqual(enc, b) {
			t.Errorf("%s: encode = %x, want %x", v.Name, enc, b)
		}
	}
}
