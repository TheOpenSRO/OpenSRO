package retailsrv

// Round 788, lane S: the login rules hold on the original client's path too
// -- the gateway's 0x6102 decides through LoginService.Login with no session,
// the agent's 0x6103 enters the account on the session that plays
// (AdmitSession), and the agent's disconnect releases it.

import (
	"bytes"
	"net"
	"strconv"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/retailgw"
	"github.com/TheOpenSRO/OpenSRO/server/internal/session"
)

func TestRetailPathLoginRules(t *testing.T) {
	var svc *session.LoginService
	h := newHarnessWith(t, func(store *account.MemStore) *session.LoginService {
		svc = &session.LoginService{Accounts: store, Online: session.NewOnlineAccounts(),
			Rules: session.LoginRules{BlockMinutes: 10, PunishmentGuide: "slow down"}}
		return svc
	})
	for _, n := range []string{"alice", "bob", "carol", "dave"} {
		if _, err := h.accounts.Add(n, "pw"); err != nil {
			t.Fatal(err)
		}
	}
	closed := func(c *retailgw.ClientConn) bool {
		t.Helper()
		_, err := c.Recv()
		return err != nil
	}

	// Wrong passwords: max and used filled, the connection open below the
	// tolerance and closed at it; then the automatic block.
	gw, _ := h.gatewayReady()
	for used := uint32(1); used <= 3; used++ {
		ack := h.login(gw, "alice", "x", 7)
		if ack.OK || ack.Code != session.LoginErrPassword || ack.MaxAttempts != 3 || ack.UsedAttempts != used {
			t.Fatalf("wrong password %d: %+v", used, ack)
		}
	}
	if !closed(gw) {
		t.Fatal("the gateway stayed open after the last allowed wrong password")
	}
	gw, _ = h.gatewayReady()
	// The end on the wire is the server's local wall time, 10 minutes on.
	end := time.Now().Add(10 * time.Minute)
	wall := time.Date(end.Year(), end.Month(), end.Day(), end.Hour(), end.Minute(), end.Second(), 0, time.UTC)
	if ack := h.login(gw, "alice", "pw", 7); ack.Code != session.LoginErrBlocked || ack.BlockKind != session.LoginBlockPunished ||
		ack.BlockReason != "slow down" || ack.BlockEnd.Sub(wall).Abs() > time.Minute {
		t.Fatalf("blocked: %+v (end want about %v)", ack, wall)
	}

	agentIn := func(user string, tok uint32) (*retailgw.ClientConn, []byte) {
		t.Helper()
		ag := h.dial(net.JoinHostPort("127.0.0.1", strconv.Itoa(int(h.cfg.AgentPort))))
		if _, err := ag.ReadIdentity(); err != nil {
			t.Fatal(err)
		}
		h.send(ag, OpAgentLogin, (&AgentLogin{Token: tok, ID: user, PW: "pw", ContentID: 22}).Encode())
		return ag, h.expect(ag, OpAgentLoginReply).Payload
	}
	gatewayIn := func(user string) *session.LoginAck {
		t.Helper()
		gw, _ := h.gatewayReady()
		ack := h.login(gw, user, "pw", 7)
		if !ack.OK {
			if !closed(gw) && ack.Code != session.LoginErrBlocked {
				t.Errorf("%s: the gateway stayed open after %+v", user, ack)
			}
		} else {
			gw.Close()
		}
		return ack
	}

	// bob in through the agent: the agent session is the one entered.
	ack := gatewayIn("bob")
	if !ack.OK {
		t.Fatalf("bob at the gateway: %+v", ack)
	}
	bobAgent, got := agentIn("bob", ack.Token)
	if !bytes.Equal(got, []byte{1}) {
		t.Fatalf("bob at the agent: %v", got)
	}
	if svc.Online.Count() != 1 {
		t.Fatalf("online %d after bob's agent login, want 1", svc.Online.Count())
	}
	// bob again: refused at the gateway with [2,3], connection closed.
	if ack := gatewayIn("bob"); ack.OK || ack.Code != session.LoginErrAlreadyConnected {
		t.Fatalf("bob's second login: %+v", ack)
	}

	// carol twice before either 0x6103: both pass the gateway; the second at
	// the agent finds the first and is refused [2,2], closed.
	a1, a2 := gatewayIn("carol"), gatewayIn("carol")
	if !a1.OK || !a2.OK {
		t.Fatalf("carol at the gateway: %+v %+v", a1, a2)
	}
	if _, got := agentIn("carol", a1.Token); !bytes.Equal(got, []byte{1}) {
		t.Fatalf("carol's first agent login: %v", got)
	}
	ag2, got := agentIn("carol", a2.Token)
	if !bytes.Equal(got, []byte{2, AgentErrRegistration}) || !closed(ag2) {
		t.Fatalf("carol's second agent login: %v", got)
	}

	// The per-IP limit at the gateway: two accounts in from 127.0.0.1.
	svc.Rules.MaxPerIP = 2
	if ack := gatewayIn("dave"); ack.OK || ack.Code != session.LoginErrIPLimit {
		t.Fatalf("dave past the IP limit: %+v", ack)
	}
	svc.Rules.MaxPerIP = 0

	// bob's agent connection ends: the agent's OnDisconnect frees him.
	bobAgent.Close()
	deadline := time.Now().Add(2 * time.Second)
	for svc.Online.Count() != 1 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if ack := gatewayIn("bob"); !ack.OK {
		t.Fatalf("bob after his agent session ended: %+v", ack)
	}
}
