package retailgw

// The fake gateway's login (round 788): 0x6102 with the image code (IBUV)
// and 0xA102 on the gateway connection, 0x6103 / 0xA103 and the lobby's
// character list on the agent connection -- enough to drive the whole legacy
// path of the Godot client and RunLogin against the same server and record
// what each sends. The retail behaviour it plays is RESEARCH section 1 of
// round 788 (READ, GatewayServer, GlobalManager, AgentServer); what is the
// fake's own is marked OURS. Server.onFrame hands it every frame its
// list-only switch does not take (onLoginFrame).

import (
	"bytes"
	"compress/zlib"
	"encoding/binary"
	"fmt"
	"strings"
)

// FakeLogin is the fake's one account and the answers it gives.
type FakeLogin struct {
	Username string
	Password string
	// Captcha is the right image code; IBUV is issued for every login whose
	// password is right (READ, gateway -> GlobalManager -> 0x2322).
	Captcha string
	// Image is the 0x2322 blob sent with each image.
	Image []byte
	// PasswordMax and CaptchaMax are the tolerances (READ:
	// LoginFailureTolerance, IBUVFailureTolerance; 0 means 3, the code's
	// default).
	PasswordMax uint32
	CaptchaMax  uint32
	// Reply, when set, is the 0xA102 payload sent for the right password
	// instead of the image (a refusal: blocked, already connected, ...), and
	// the connection is closed after it (READ: the gateway disconnects after
	// every GlobalManager refusal).
	Reply []byte
	// Token and the agent address 0xA102 names on success.
	Token     uint32
	AgentHost string
	AgentPort uint16
	// AgentReply, when set, is the 0xA103 payload instead of [1].
	AgentReply []byte
	// Lobby is the 0xB007 payload answering 0x7007 [2].
	Lobby []byte
	// AgentFrom is the first connection served as the agent (0 means 1:
	// connection 0 is the gateway, OURS).
	AgentFrom int
}

// fakeLoginConn is one connection's login state.
type fakeLoginConn struct {
	pwFails, ibuvFails uint32
	user               string
	pass               string
}

func (sc *sconn) loginCfg() *FakeLogin { return sc.s.cfg.Login }

// isAgent reports a connection the fake serves as the agent.
func (sc *sconn) isAgent() bool {
	l := sc.loginCfg()
	if l == nil {
		return false
	}
	from := l.AgentFrom
	if from == 0 {
		from = 1
	}
	return sc.n >= from
}

func tolerance(v uint32) uint32 {
	if v == 0 {
		return 3
	}
	return v
}

// The fake's own replies go plain (OURS: which of the gateway's and agent's
// login replies are encrypted is not settled; the client reads either).
func (sc *sconn) reply(op uint16, payload []byte) error { return sc.frame(op, payload, false) }

func le32(v ...uint32) []byte {
	var b []byte
	for _, x := range v {
		b = binary.LittleEndian.AppendUint32(b, x)
	}
	return b
}

// onLoginFrame takes the login's frames (done ends the connection).
func (sc *sconn) onLoginFrame(op uint16, payload []byte) (bool, error) {
	l := sc.loginCfg()
	if l == nil {
		return false, nil
	}
	if sc.fl == nil {
		sc.fl = &fakeLoginConn{}
	}
	switch op {
	case OpGatewayLogin:
		r := &reader{p: payload}
		_, err1 := r.u8()
		user, err2 := r.str()
		pass, err3 := r.str()
		_, err4 := r.u16()
		if err1 != nil || err2 != nil || err3 != nil || err4 != nil || !r.done() {
			return true, fmt.Errorf("0x6102: malformed")
		}
		sc.fl.user, sc.fl.pass = user, pass
		if !strings.EqualFold(user, l.Username) || pass != l.Password {
			// READ (GlobalManager 0x464ac0): counted per account; at the
			// tolerance the gateway sends [2,1,max,used] and closes.
			sc.fl.pwFails++
			mx := tolerance(l.PasswordMax)
			if err := sc.reply(OpGatewayLoginAck, append([]byte{2, 1}, le32(mx, sc.fl.pwFails)...)); err != nil {
				return true, err
			}
			return sc.fl.pwFails >= mx, nil
		}
		if l.Reply != nil {
			return true, sc.reply(OpGatewayLoginAck, l.Reply)
		}
		return false, sc.sendImage()
	case OpCaptchaAnswer:
		r := &reader{p: payload}
		code, err := r.str()
		if err != nil || !r.done() {
			return true, fmt.Errorf("0x6323: malformed")
		}
		if code != l.Captcha {
			// READ: 0xA323 [2, max, used]; below the tolerance a new image,
			// at it a disconnect.
			sc.fl.ibuvFails++
			mx := tolerance(l.CaptchaMax)
			if err := sc.reply(OpCaptchaResult, append([]byte{2}, le32(mx, sc.fl.ibuvFails)...)); err != nil {
				return true, err
			}
			if sc.fl.ibuvFails >= mx {
				return true, nil
			}
			return false, sc.sendImage()
		}
		// READ: 0xA323 [1], then the shard's admission and 0xA102 success.
		if err := sc.reply(OpCaptchaResult, []byte{1}); err != nil {
			return true, err
		}
		var w writer
		w.u8(1)
		w.u32(l.Token)
		w.str(l.AgentHost)
		w.u16(l.AgentPort)
		return false, sc.reply(OpGatewayLoginAck, w.b)
	case OpAgentLogin:
		r := &reader{p: payload}
		token, err1 := r.u32()
		user, err2 := r.str()
		pass, err3 := r.str()
		_, err4 := r.u8()
		_, err5 := r.bytes(6)
		if err1 != nil || err2 != nil || err3 != nil || err4 != nil || err5 != nil || !r.done() {
			return true, fmt.Errorf("0x6103: malformed")
		}
		if l.AgentReply != nil {
			return true, sc.reply(OpAgentLoginAck, l.AgentReply)
		}
		// READ (AgentServer 0x402120): the token and credentials must match
		// the queued login, else [2,1] / [2,3].
		if token != l.Token {
			return true, sc.reply(OpAgentLoginAck, []byte{2, 3})
		}
		if user != strings.ToLower(l.Username) || pass != l.Password {
			return true, sc.reply(OpAgentLoginAck, []byte{2, 1})
		}
		return false, sc.reply(OpAgentLoginAck, []byte{1})
	case OpLobby:
		if len(payload) == 1 && payload[0] == 2 && l.Lobby != nil {
			return false, sc.reply(OpLobbyResult, l.Lobby)
		}
		return false, nil
	}
	return false, nil // OURS: anything else (a keep-alive) is passed over
}

// EncodeCaptchaBlob builds a 0x2322 image blob as GatewayServer's IBUV module
// does (READ: ImageTrans.dll fnImageTransToMemW, 0x10007b2b..0x10007b65):
// u16 compressed length, u16 output size (H+1)*W, u16 W, u16 H, then the
// zlib stream (compress2, level 9) of a 1-bit picture, rows top-down, W/8
// bytes a row, pixel (x, y) bit (x & 7) of byte (y*W + x) >> 3. W must be a
// multiple of 8 (the writer rounds it up).
func EncodeCaptchaBlob(w, h int, on func(x, y int) bool) ([]byte, error) {
	if w <= 0 || h <= 0 || w%8 != 0 {
		return nil, fmt.Errorf("captcha: %d x %d", w, h)
	}
	bits := make([]byte, w*h/8)
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			if on(x, y) {
				bits[(y*w+x)>>3] |= 1 << (x & 7)
			}
		}
	}
	var z bytes.Buffer
	zw, err := zlib.NewWriterLevel(&z, zlib.BestCompression)
	if err != nil {
		return nil, err
	}
	if _, err := zw.Write(bits); err != nil {
		return nil, err
	}
	if err := zw.Close(); err != nil {
		return nil, err
	}
	var out writer
	out.u16(uint16(z.Len()))
	out.u16(uint16((h + 1) * w))
	out.u16(uint16(w))
	out.u16(uint16(h))
	return append(out.b, z.Bytes()...), nil
}

// sendImage sends 0x2322 [u8 flag 0, u16 n, blob] (READ layout; the flag's
// value is the fake's, OURS).
func (sc *sconn) sendImage() error {
	l := sc.loginCfg()
	var w writer
	w.u8(0)
	w.u16(uint16(len(l.Image)))
	w.b = append(w.b, l.Image...)
	return sc.reply(OpCaptchaImage, w.b)
}
