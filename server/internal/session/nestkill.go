package session

import (
	"math"
	"sync/atomic"

	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/party"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// The kill's word to the nests (round 660, internal/nest). The engine's death
// command (CAIState slot 7, FUN_00558f20) is handed a count of the killer's
// party -- GObjPC::FUN_005bca60's: the members of the killer's exp-sharing
// party that are alive and within 1000.0 units -- and when that count is above
// 1 it arms the dead monster's nest (`nest+0x30 = 1`), whose next rarity-0
// hatch is then a party monster at 50 % (nest.RollClass). performAttack counts
// the members (partyMembersNear) and tells the observer cmd/server installs.

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

// noteMonsterKilled tells the observer of a kill.
func noteMonsterKilled(hub *world.Hub, parties *party.Hub, killer int64, m combat.Monster) {
	f := monsterKillObserver.Load()
	if f == nil {
		return
	}
	(*f)(m, partyMembersNear(hub, parties, killer, m))
}

// partyMembersNear is the death command's count: the members of killer's
// party -- a party of two or more, which every OpenSRO party is by the time
// it shares (inPartyWithOthers; every OpenSRO party shares experience, the
// flag FUN_005bca60 asserts, `party+0x10 & 1`) -- that are in the world,
// alive, in the monster's zone and at most nest.PartyArmRange (1000.0, the
// double at 0xb45c68) from the dead monster on the ground plane. READ: the
// range, the alive test (each member's slot 0xf8) and the same-world test
// (slot 0x14). INFERRED: the point the range is measured from -- the object
// FUN_005bca60 is handed, the dead monster whose experience it shares out.
// 0 for a killer in no party of two or more.
//
// (Round 709: the INFERRED point is WRONG. FUN_005bca60 measures from the
// KILL CREDIT -- the biggest hitter of the most-damaging group, READ at
// 0x5bcacb-0x5bcb29 -- in the same world, horizontally with 1920-unit region
// steps. Only an exp-share kill arms (a free-for-all kill leaves the count at
// 0, READ 0x529e0a), and instance worlds gate on PARTYMONSTER_SPAWN. This
// function still counts the old way; party lane S2 fixes it.
// docs/protocol/party_rules.md, "Party monsters".)
func partyMembersNear(hub *world.Hub, parties *party.Hub, killer int64, m combat.Monster) int {
	if hub == nil || !inPartyWithOthers(parties, killer) {
		return 0
	}
	p, _ := parties.Get(killer)
	n := 0
	for _, mem := range p.Members {
		e, ok := hub.EntityByCharacterID(mem.CharacterID)
		if !ok || e.Zone != m.Zone || e.Life == world.LifeDead {
			continue
		}
		if math.Hypot(e.Pos.X-m.X, e.Pos.Z-m.Z) <= partyArmRange {
			n++
		}
	}
	return n
}

// partyArmRange is nest.PartyArmRange, kept here so session does not import
// the nest package for one number (the test pins the two equal).
const partyArmRange = 1000.0
