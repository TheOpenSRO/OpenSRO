package session

import (
	"sync/atomic"

	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/party"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// The kill's word to the nests (round 660, internal/nest; round 712). The
// engine's death command (CAIState slot 7, FUN_00558f20) is handed the count
// GObjPC::FUN_005bca60 writes -- the eligible members of an exp-share group's
// party share -- and when that count is above 1 it arms the dead monster's
// nest (`nest+0x30 = 1`), whose next hatch of a rolling species is then a
// party monster at 50 in 101 (nest.RollClass). The kill paths count
// (partyMembersNear) and tell the observer cmd/server installs.

// MonsterKillObserver is told of each monster a player's blow kills, with the
// count of the killer's party members near it.
type MonsterKillObserver func(m combat.Monster, members int)

var monsterKillObserver atomic.Pointer[MonsterKillObserver]

// SetMonsterKillObserver installs the observer (nil removes it). cmd/server
// installs the nest scheduler's party arming before the gateway serves.
func SetMonsterKillObserver(f MonsterKillObserver) {
	if f == nil {
		monsterKillObserver.Store(nil)
		return
	}
	monsterKillObserver.Store(&f)
}

// noteMonsterKilled tells the observer of a kill, with the death command's
// count: the eligible members of the last exp-share group the distributor
// paid (planKill's armCount; round 712). hits is the monster's damage list as
// the killing blow returned it.
func noteMonsterKilled(hub *world.Hub, parties *party.Hub, hits []combat.Hit, m combat.Monster) {
	f := monsterKillObserver.Load()
	if f == nil {
		return
	}
	(*f)(m, partyMembersNear(hub, parties, hits, m))
}

// partyMembersNear is the count FUN_005bca60 writes for the death command
// (round 712; party_rules.md "Party monsters"): only an exp-share group's
// party share writes it, as the number of members alive, in the world and
// within 1000 units horizontally (inclusive) of the KILL CREDIT -- the biggest
// hitter of the most-damaging group, READ at 0x5bcacb-0x5bcb29 -- whether or
// not they dealt damage. A kill with no exp-share group leaves it at 0: the
// death function zeroes it before the distributor runs (0x529e0a), so a
// free-for-all kill never arms. With several exp-share groups the last one
// written wins (planKill's group order, OURS).
//
// Round 660 counted the killer's party, of any type, from the dead monster;
// round 709 read the kill credit and the exp-share gate.
//
// The per-world PARTYMONSTER_SPAWN gate (0x6086eb, 0x609900) strips the party
// flag in a data-driven (instance) world whose key is not ON. OpenSRO spawns
// only the field world (nest.FieldWorldID, internal/nest/join.go), where
// whether an equivalent gate exists is OPEN; so no gate is applied.
func partyMembersNear(hub *world.Hub, parties *party.Hub, hits []combat.Hit, m combat.Monster) int {
	return planKill(hub, parties, m, presentHits(hub, hits), nil).armCount
}

// partyArmRange is nest.PartyArmRange, kept here so session does not import
// the nest package for one number (the test pins the two equal).
const partyArmRange = 1000.0
