package retailgw

// The client's side of a retail login (round 788), past the shard list: the
// Conversation goes on from 0xA101 with 0x6102, the image code (IBUV) and
// 0xA102, and a second Conversation on the agent connection sends 0x6103,
// reads 0xA103 and then carries the character lobby. The Godot client's
// RetailGatewayClient is the same machine; the transcripts in
// client/scripts/frontend/testdata/retail_login_transcripts.json hold the
// two to identical bytes (TestLoginTranscripts, retail_login_test.gd).
//
// The facts are RESEARCH section 1 of round 788 and
// docs/protocol/opcodes/gateway.md, "Logging in"; each is labelled there.
// The 0xA102 payload's full codec is session.LoginAck (its golden twin is the
// Godot client's LoginAckNet); this package keeps its own small reader so it
// does not import the session package (OURS: no import cycle with a
// server-side retail listener).

import (
	"context"
	"errors"
	"fmt"
	"net"
	"strings"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/proto"
)

// Opcodes of the login (READ: the client builds 0x6102 in CClientNet::vslot_004
// 0x4c9290 and reads 0xA102 in CClientProcess::vslot_017 0x4cf500; 0x2322 in
// 0x4cd3c0; 0x6323 in 0x4c96a0; 0xA323 in 0x4d0230; 0x6103 at 0x4ceb86;
// 0xA103 in vslot_018 0x4cf7a0; the lobby 0x7007/0xB007, charselect.md).
const (
	OpGatewayLogin    uint16 = 0x6102
	OpGatewayLoginAck uint16 = 0xA102
	OpCaptchaImage    uint16 = 0x2322
	OpCaptchaAnswer   uint16 = 0x6323
	OpCaptchaResult   uint16 = 0xA323
	OpAgentLogin      uint16 = 0x6103
	OpAgentLoginAck   uint16 = 0xA103
	OpLobby           uint16 = 0x7007
	OpLobbyResult     uint16 = 0xB007
	OpKeepAlive       uint16 = 0x2002
)

// AgentModule is the agent's identity in 0x2001 (READ: the client sends
// 0x6103 once the server names itself "AgentServer", 0x4ceb36).
const AgentModule = "AgentServer"

// Which client frames go encrypted (READ: the allocator's argument at each
// send; docs/protocol/opcodes/gateway.md, "Logging in").
var clientEncrypts = map[uint16]bool{
	OpGatewayLogin:  true,  // 0x4c9290
	OpAgentLogin:    true,  // 0x4ceb86
	OpCaptchaAnswer: false, // 0x4c96ab: allocator argument 0
	OpLobby:         false, // the generic sender 0x841590 encrypts only 0x704C
	OpKeepAlive:     false, // CClientProcess::vslot_025 0x4cf990: allocator argument 0
}

// LoginParams is what the player typed and chose.
type LoginParams struct {
	Username string
	Password string
	// Shard is the chosen server's name, matched against the list (READ:
	// the Connect handler 0x8688f0 matches static 43's name against the
	// shard list at +0x1b4).
	Shard string
}

// AgentParams opens an agent Conversation: the token of the 0xA102 and the
// ID and password the gateway took.
type AgentParams struct {
	Token    uint32
	Username string // sent lower-cased (READ, _strlwr_s 0x4c9374)
	Password string
	// Trailer is 0x6103's last 6 bytes (READ: from the net engine's slot
	// 0x88; what they are: docs/protocol/opcodes/gateway.md).
	Trailer [6]byte
}

// LoginReply is a 0xA102 as this package reads it.
type LoginReply struct {
	OK        bool
	Token     uint32
	AgentHost string
	AgentPort uint16
	Code      byte
	Raw       []byte
}

// CaptchaImage is a 0x2322 payload (READ, client 0x4cd3c0): u8 flag, u16 n,
// n bytes of image.
type CaptchaImage struct {
	Flag byte
	Blob []byte
}

// LoginEvent is something the player is told or asked.
type LoginEvent struct {
	Kind   string // login_ok, login_failed, captcha, captcha_ok, captcha_failed, agent_ok, agent_failed, frame
	Reply  LoginReply
	Image  CaptchaImage
	Max    uint32
	Used   uint32
	Code   byte
	Opcode uint16
	Data   []byte
}

// The states past the list (convState continues client.go's).
const (
	stLogin       convState = iota + 100 // 0x6102 out, waiting for 0xA102 or 0x2322
	stCaptcha                            // the image is up, waiting for the player
	stLoginIdle                          // a refusal shown; the player may try again
	stAuthed                             // 0xA102 success: the gateway's part is over
	stAgentAuth                          // 0x6103 out, waiting for 0xA103
	stLobby                              // logged in on the agent
	stAgentFailed                        // 0xA103 refused
)

// capped reports the states whose frames count against MaxFrames: the
// exchange up to the list and the agent's up to 0xA103 (OURS: past them the
// connection is a session, not a question).
func (c *Conversation) capped() bool {
	return c.state <= stList || c.state == stAgentAuth
}

// Authed reports a successful 0xA102; InLobby a successful 0xA103.
func (c *Conversation) Authed() bool  { return c.state == stAuthed }
func (c *Conversation) InLobby() bool { return c.state == stLobby }

// TakeEvents returns the events so far and forgets them.
func (c *Conversation) TakeEvents() []LoginEvent {
	ev := c.events
	c.events = nil
	return ev
}

func (c *Conversation) event(e LoginEvent) { c.events = append(c.events, e) }

// PickShard is the chosen shard's id: the one named Shard, or the list's
// only shard when none is (OURS: the server list may have been chosen by its
// config name).
func PickShard(l ShardList, name string) (uint16, error) {
	for _, s := range l.Shards {
		if s.Name == name {
			return s.ID, nil
		}
	}
	if len(l.Shards) == 1 {
		return l.Shards[0].ID, nil
	}
	return 0, fmt.Errorf("the gateway lists no shard named %q", name)
}

// EncodeGatewayLogin is a 0x6102 payload (READ 0x4c9290): u8 content id,
// string ID (as typed), string password, u16 shard id.
func EncodeGatewayLogin(contentID byte, user, pass string, shard uint16) []byte {
	var w writer
	w.u8(contentID)
	w.str(user)
	w.str(pass)
	w.u16(shard)
	return w.b
}

// EncodeAgentLogin is a 0x6103 payload (READ 0x4ceb86): u32 token, string ID
// lower-cased, string password, u8 content id, 6 bytes.
func EncodeAgentLogin(token uint32, user, pass string, contentID byte, trailer [6]byte) []byte {
	var w writer
	w.u32(token)
	w.str(strings.ToLower(user))
	w.str(pass)
	w.u8(contentID)
	w.b = append(w.b, trailer[:]...)
	return w.b
}

// EncodeCaptchaAnswer is a 0x6323 payload (READ 0x4c96a0): the code.
func EncodeCaptchaAnswer(code string) []byte {
	var w writer
	w.str(code)
	return w.b
}

// DecodeLoginReply reads a 0xA102 (strictly on success; a refusal keeps its
// bytes in Raw for the caller's codec).
func DecodeLoginReply(p []byte) (LoginReply, error) {
	r := &reader{p: p}
	res, err := r.u8()
	if err != nil {
		return LoginReply{}, fmt.Errorf("0xA102: empty")
	}
	out := LoginReply{Raw: append([]byte(nil), p...)}
	switch res {
	case 1:
		out.OK = true
		if out.Token, err = r.u32(); err != nil {
			return out, fmt.Errorf("0xA102: short token")
		}
		if out.AgentHost, err = r.str(); err != nil {
			return out, fmt.Errorf("0xA102 agent host: %w", err)
		}
		if out.AgentPort, err = r.u16(); err != nil || !r.done() {
			return out, fmt.Errorf("0xA102: not a u16 port at the end")
		}
		return out, nil
	case 2:
		if out.Code, err = r.u8(); err != nil {
			return out, fmt.Errorf("0xA102: no error code")
		}
		return out, nil
	}
	return out, fmt.Errorf("0xA102: result %d", res)
}

// DecodeCaptchaImage reads a 0x2322 (READ 0x4cd3c0).
func DecodeCaptchaImage(p []byte) (CaptchaImage, error) {
	r := &reader{p: p}
	flag, err := r.u8()
	if err != nil {
		return CaptchaImage{}, fmt.Errorf("0x2322: empty")
	}
	n, err := r.u16()
	if err != nil {
		return CaptchaImage{}, fmt.Errorf("0x2322: no length")
	}
	b, err := r.bytes(int(n))
	if err != nil || !r.done() {
		return CaptchaImage{}, fmt.Errorf("0x2322: %d bytes announced, %d there", n, len(p)-3)
	}
	return CaptchaImage{Flag: flag, Blob: append([]byte(nil), b...)}, nil
}

// sendLogin follows the list with 0x6102 (Conversation.Frame calls it when
// Login is set).
func (c *Conversation) sendLogin() ([][]byte, error) {
	id, err := PickShard(c.List, c.Login.Shard)
	if err != nil {
		return nil, err
	}
	c.shardID = id
	c.state = stLogin
	return c.send(OpGatewayLogin, EncodeGatewayLogin(c.Info.ContentID, c.Login.Username, c.Login.Password, id), clientEncrypts[OpGatewayLogin])
}

// Resubmit sends 0x6102 again on the same connection after a refusal (READ:
// below the tolerance the gateway keeps the connection open).
func (c *Conversation) Resubmit(user, pass string) ([][]byte, error) {
	if c.state != stLoginIdle {
		return nil, fmt.Errorf("no login to retry in state %d", c.state)
	}
	c.Login.Username, c.Login.Password = user, pass
	c.state = stLogin
	return c.send(OpGatewayLogin, EncodeGatewayLogin(c.Info.ContentID, user, pass, c.shardID), clientEncrypts[OpGatewayLogin])
}

// SubmitCaptcha answers the image with the typed code.
func (c *Conversation) SubmitCaptcha(code string) ([][]byte, error) {
	if c.state != stCaptcha {
		return nil, fmt.Errorf("no image code asked for in state %d", c.state)
	}
	c.state = stLogin
	return c.send(OpCaptchaAnswer, EncodeCaptchaAnswer(code), clientEncrypts[OpCaptchaAnswer])
}

// SendLobby sends one lobby request on the agent connection.
func (c *Conversation) SendLobby(op uint16, payload []byte) ([][]byte, error) {
	if c.state != stLobby {
		return nil, fmt.Errorf("not in the lobby (state %d)", c.state)
	}
	return c.send(op, payload, clientEncrypts[op])
}

// KeepAlive is the keep-alive frame (docs/protocol/opcodes/gateway.md).
func (c *Conversation) KeepAlive() ([][]byte, error) {
	return c.send(OpKeepAlive, nil, clientEncrypts[OpKeepAlive])
}

// agentIdentity is the agent's 0x2001: "AgentServer" gets 0x6103.
func (c *Conversation) agentIdentity(name string) ([][]byte, error) {
	if name != AgentModule {
		return nil, fmt.Errorf("the server is %q, not %s (the client logs in only to an agent here)", name, AgentModule)
	}
	a := c.Agent
	c.state = stAgentAuth
	return c.send(OpAgentLogin, EncodeAgentLogin(a.Token, a.Username, a.Password, c.Info.ContentID, a.Trailer), clientEncrypts[OpAgentLogin])
}

// loginFrame handles one frame past the list, on either connection.
func (c *Conversation) loginFrame(op uint16, data []byte) ([][]byte, error) {
	switch c.state {
	case stLogin, stCaptcha, stLoginIdle:
		switch op {
		case OpGatewayLoginAck:
			rep, err := DecodeLoginReply(data)
			if err != nil {
				return nil, err
			}
			if rep.OK {
				c.state = stAuthed
				c.event(LoginEvent{Kind: "login_ok", Reply: rep})
				return nil, nil
			}
			c.state = stLoginIdle
			c.event(LoginEvent{Kind: "login_failed", Reply: rep, Code: rep.Code})
		case OpCaptchaImage:
			img, err := DecodeCaptchaImage(data)
			if err != nil {
				return nil, err
			}
			c.state = stCaptcha
			c.event(LoginEvent{Kind: "captcha", Image: img})
		case OpCaptchaResult:
			r := &reader{p: data}
			res, err := r.u8()
			if err != nil {
				return nil, fmt.Errorf("0xA323: empty")
			}
			if res == 1 && r.done() {
				c.event(LoginEvent{Kind: "captcha_ok"})
				return nil, nil
			}
			mx, err1 := r.u32()
			used, err2 := r.u32()
			if res != 2 || err1 != nil || err2 != nil || !r.done() {
				return nil, fmt.Errorf("0xA323: not [1] or [2, u32 max, u32 used]")
			}
			c.event(LoginEvent{Kind: "captcha_failed", Max: mx, Used: used})
		}
		return nil, nil // OURS: anything else is passed over
	case stAgentAuth:
		if op != OpAgentLoginAck {
			return nil, nil
		}
		if len(data) == 1 && data[0] == 1 {
			c.state = stLobby
			c.event(LoginEvent{Kind: "agent_ok"})
			return nil, nil
		}
		if len(data) != 2 || data[0] != 2 {
			return nil, fmt.Errorf("0xA103: not [1] or [2, code]")
		}
		c.state = stAgentFailed
		c.event(LoginEvent{Kind: "agent_failed", Code: data[1]})
		return nil, nil
	case stLobby:
		c.event(LoginEvent{Kind: "frame", Opcode: op, Data: append([]byte(nil), data...)})
		return nil, nil
	}
	return nil, fmt.Errorf("a frame after the login ended (state %d)", c.state)
}

// LoginOptions drive one RunLogin (OURS, the reference the Godot client's
// RetailLogin is held to).
type LoginOptions struct {
	Info  ClientInfo
	Login LoginParams
	// Captcha answers each image (attempt counts from 1).
	Captcha func(img CaptchaImage, attempt int) string
	// Agent, when set, is dialled instead of the address the 0xA102 names
	// (the config's `agent:` entry, ClientConfig; tests).
	Agent   string
	Trailer [6]byte
	// PrivateX, when set, is each connection's private value (tests).
	PrivateX *uint32
	Budget   time.Duration
}

// LoginResult is how RunLogin ended.
type LoginResult struct {
	Events []LoginEvent
	// Lobby is the 0xB007 payload answering the character list.
	Lobby []byte
}

// RunLogin logs in at the gateway at addr, then at the agent, and asks for
// the character list; it returns at the first refusal, or with the list.
func RunLogin(ctx context.Context, addr string, opt LoginOptions) (LoginResult, error) {
	if opt.Budget <= 0 {
		opt.Budget = 8 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, opt.Budget)
	defer cancel()
	var res LoginResult
	gw := NewConversation(opt.Info)
	if opt.PrivateX != nil {
		gw.PrivateX = *opt.PrivateX
	}
	lp := opt.Login
	gw.Login = &lp
	attempts := 0
	var rep LoginReply
	err := drive(ctx, addr, gw, func(c *Conversation, ev LoginEvent) ([][]byte, bool, error) {
		res.Events = append(res.Events, ev)
		switch ev.Kind {
		case "captcha":
			attempts++
			code := ""
			if opt.Captcha != nil {
				code = opt.Captcha(ev.Image, attempts)
			}
			out, err := c.SubmitCaptcha(code)
			return out, false, err
		case "login_ok":
			rep = ev.Reply
			return nil, true, nil
		case "login_failed":
			return nil, true, nil
		}
		return nil, false, nil
	})
	if err != nil || !gw.Authed() {
		return res, err
	}
	agentAddr := opt.Agent
	if agentAddr == "" {
		agentAddr = net.JoinHostPort(rep.AgentHost, fmt.Sprint(rep.AgentPort))
	}
	ag := NewConversation(opt.Info)
	if opt.PrivateX != nil {
		ag.PrivateX = *opt.PrivateX
	}
	ag.Agent = &AgentParams{Token: rep.Token, Username: opt.Login.Username, Password: opt.Login.Password, Trailer: opt.Trailer}
	err = drive(ctx, agentAddr, ag, func(c *Conversation, ev LoginEvent) ([][]byte, bool, error) {
		res.Events = append(res.Events, ev)
		switch ev.Kind {
		case "agent_ok":
			// READ: character select's OnCreate asks for the list (0x7007 [2]).
			out, err := c.SendLobby(OpLobby, []byte{2})
			return out, false, err
		case "agent_failed":
			return nil, true, nil
		case "frame":
			if ev.Opcode == OpLobbyResult {
				res.Lobby = ev.Data
				return nil, true, nil
			}
		}
		return nil, false, nil
	})
	return res, err
}

// drive runs one connection until on says stop.
func drive(ctx context.Context, addr string, c *Conversation, on func(*Conversation, LoginEvent) ([][]byte, bool, error)) error {
	var d net.Dialer
	conn, err := d.DialContext(ctx, "tcp", addr)
	if err != nil {
		return err
	}
	defer conn.Close()
	if dl, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(dl)
	}
	write := func(out [][]byte) error {
		for _, o := range out {
			if _, err := conn.Write(o); err != nil {
				return err
			}
		}
		return nil
	}
	var buf []byte
	tmp := make([]byte, 4096)
	for {
		for {
			n, err := proto.RetailFrameLen(buf)
			if errors.Is(err, proto.ErrRetailNeedMore) {
				break
			}
			if err != nil {
				return err
			}
			out, err := c.Frame(buf[:n])
			buf = buf[n:]
			if err != nil {
				return err
			}
			if err := write(out); err != nil {
				return err
			}
			for _, ev := range c.TakeEvents() {
				more, stop, err := on(c, ev)
				if err != nil {
					return err
				}
				if err := write(more); err != nil {
					return err
				}
				if stop {
					return nil
				}
			}
		}
		n, err := conn.Read(tmp)
		if n > 0 {
			buf = append(buf, tmp[:n]...)
		}
		if err != nil {
			return fmt.Errorf("the connection ended: %w", err)
		}
	}
}
