package retailsrv

import (
	"context"
	"io"
	"log/slog"
	"net"
	"strconv"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/charlock"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/session"
)

// TestRetailAgentHonoursThePin: the original client has no PIN window, so on
// an account with a PIN its list still works and its delete is refused, as
// on OpenSRO's own connection (round 788 merge: main.go hands the agent the
// lobby behind session.CharacterLockGate; docs/protocol/pin.md).
func TestRetailAgentHonoursThePin(t *testing.T) {
	svc := &charlock.Service{Store: charlock.NewMemStore()}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	h := newHarnessLobby(t, nil, func(next gateway.Handler) gateway.Handler {
		return session.CharacterLockGate(svc, logger, next)
	})
	acc, err := h.accounts.Add("alice", "secret")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := h.chars.CreateCharacter(context.Background(), acc.ID, character.NewCharacter{Name: "Hero", RefObjID: 1907, Scale: 0x22, Gender: "male"}); err != nil {
		t.Fatal(err)
	}
	if code, err := svc.Create(context.Background(), acc.ID, "2580"); err != nil || code != charlock.OK {
		t.Fatalf("create the PIN: %v, %v", code, err)
	}
	gw, _ := h.gatewayReady()
	ack := h.login(gw, "alice", "secret", 7)
	if !ack.OK {
		t.Fatalf("login: %+v", ack)
	}
	gw.Close()
	ag := h.dial(net.JoinHostPort(ack.AgentHost, strconv.Itoa(int(ack.AgentPort))))
	if _, err := ag.ReadIdentity(); err != nil {
		t.Fatal(err)
	}
	h.send(ag, OpAgentLogin, (&AgentLogin{Token: ack.Token, ID: "alice", PW: "secret", ContentID: 22}).Encode())
	h.expect(ag, OpAgentLoginReply)

	if err := ag.Send(OpLobby, (&session.LobbyRequest{Action: session.LobbyList}).Encode(), false); err != nil {
		t.Fatal(err)
	}
	if r, err := session.DecodeLobbyResult(h.expect(ag, OpLobbyResult).Payload); err != nil || !r.OK || len(r.Characters) != 1 {
		t.Fatalf("list on a PIN account: %+v, %v", r, err)
	}
	if err := ag.Send(OpLobby, (&session.LobbyRequest{Action: session.LobbyDelete, Name: "Hero"}).Encode(), false); err != nil {
		t.Fatal(err)
	}
	r, err := session.DecodeLobbyResult(h.expect(ag, OpLobbyResult).Payload)
	if err != nil || r.OK || r.Code != session.LobbyErrBusy {
		t.Fatalf("delete on a PIN account from the original client: %+v, %v; want refused 0x%x", r, err, session.LobbyErrBusy)
	}
	if c, err := h.chars.ListByAccount(context.Background(), acc.ID); err != nil || len(c) != 1 || c[0].Deleting() {
		t.Fatalf("the character after a refused delete: %+v, %v", c, err)
	}
}
