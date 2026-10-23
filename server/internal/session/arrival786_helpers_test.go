package session

import (
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 786's test helpers over the hub's hold (world.Entity.Held), apart
// from arrival786_test.go so the tests can be built against the tree before
// the round with a stub of these (the fail-first run, WORLD_ISSUES round 786).

// heldInHub reports whether character id is in hub and held out of the world.
func heldInHub(hub *world.Hub, id int64) bool {
	e, ok := hub.EntityByCharacterID(id)
	return ok && e.Held
}

// changeZoneHeldForTest moves sess's character to pos held.
func changeZoneHeldForTest(hub *world.Hub, sess *gateway.Session, zone string, pos world.Position) {
	hub.ChangeZoneHeld(sess, zone, pos)
}
