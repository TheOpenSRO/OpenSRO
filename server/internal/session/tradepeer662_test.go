package session

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
)

// Round 662's review (L3): a handler that sends to ANOTHER player must not
// hand that player's Send error back as its own -- a handler's error closes
// the session it serves, so a trade partner stalled by its send queue took
// the innocent player down with it. Bram stops reading and his queue passes
// its limit (ErrSendStalled); Aria then changes her offer, which tells Bram,
// and is still connected: she gets her offer's result and can go on trading.
func TestAStalledTradePartnerDoesNotDisconnectTheSender(t *testing.T) {
	old := gateway.SendQueueLimit
	gateway.SendQueueLimit = 64 << 10 // read by each session as it connects
	t.Cleanup(func() { gateway.SendQueueLimit = old })

	const opWhoAmI uint16 = 0x7ffc
	whoAmI := make(chan *gateway.Session, 1)
	f := setupTradeTestWith(t, nil, func(tradeFixtureDeps) []gateway.Handler {
		return []gateway.Handler{func(_ context.Context, s *gateway.Session, p *proto.Packet) error {
			if p.Opcode == opWhoAmI {
				whoAmI <- s
			}
			return nil
		}}
	})
	startTrade(t, f)
	if err := proto.Write(f.connB, &proto.Packet{Opcode: opWhoAmI}, nil, nil); err != nil {
		t.Fatal(err)
	}
	var bram *gateway.Session
	select {
	case bram = <-whoAmI:
	case <-time.After(2 * time.Second):
		t.Fatal("Bram's session never arrived")
	}

	// Bram never reads again: fill his queue until the gateway gives him up.
	var err error
	for i := 0; i < 100000 && err == nil; i++ {
		err = bram.Send(&proto.Packet{Opcode: 0x7ffb, Data: make([]byte, 16<<10)})
	}
	if !errors.Is(err, gateway.ErrSendStalled) {
		t.Fatalf("Bram's sends ended with %v, want ErrSendStalled", err)
	}

	// Aria changes her offer: her handler tells Bram, whose Send fails.
	for i := 0; i < 2; i++ {
		resp := doSend(t, f.connA, f.rA, OpTradeSetOffer, (&TradeSetOfferRequest{CharacterName: "Aria", Offer: TradeOffer{Gold: int64(i + 1), ItemSlot: -1}}).Encode())
		if or, err := DecodeTradeOfferResult(resp.Data); err != nil || !or.OK {
			t.Fatalf("Aria's offer %d: err=%v result=%+v", i+1, err, or)
		}
	}
}
