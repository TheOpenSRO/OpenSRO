package session

import (
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 832: the ping's token comes back unchanged; a malformed one is dropped.
func TestPingEchoes(t *testing.T) {
	f := startDeadWorldFixtureWith(t, func(chars character.Store, hub *world.Hub) gateway.Handler {
		return PingHandler()
	})
	f.send(t, f.connA, OpPing, []byte{1, 2, 3, 4})
	p := f.read(t, f.connA, f.rA)
	if p.Opcode != OpPingEcho || string(p.Data) != string([]byte{1, 2, 3, 4}) {
		t.Fatalf("got %#04x % x, want 0x00fd 01 02 03 04", p.Opcode, p.Data)
	}
	f.send(t, f.connA, OpPing, []byte{1, 2})
	if !f.nothing(t, f.connA, f.rA) {
		t.Error("a short ping was answered")
	}
}
