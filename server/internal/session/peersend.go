package session

import (
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
)

// sendToPeer sends p to another player's session from a handler serving a
// different one (a trade partner, a duel opponent, a friend) and drops the
// error (round 662's review, L3). A handler's error closes the session it is
// serving, so returning the PEER's error -- ErrSendStalled for a partner
// whose queue passed its limit, ErrSessionClosed for one that is leaving --
// disconnected the player who did nothing wrong. The peer's own failure is
// already dealt with where it happened: the gateway logs the stall and closes
// that peer's connection, and its read loop's end runs OnDisconnect.
func sendToPeer(to *gateway.Session, p *proto.Packet) {
	_ = to.Send(p)
}
