package session

import (
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/nest"
	"github.com/OpenSRO/OpenSRO/server/internal/party"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// Round 660: the party flag rides in bit 8 of the list record's rarity word,
// and only to a session whose list request carried MonsterListFlagParty; the
// rank stays the low byte either way.
func TestPartyFlagOnTheWire(t *testing.T) {
	monsters := combat.NewHub()
	m := monsters.SpawnHatched("jangan", combat.Species{Name: "Synthetic", Rarity: 1, Level: 40}, 5, 0, 6, 100, 1, 1, 0,
		combat.Hatch{HomeX: 5, HomeZ: 6, Party: true})
	if m.MaxHP != 100*2*10 {
		t.Fatalf("a party champion has %d HP, want x2 x10 = 2000", m.MaxHP)
	}
	old, asked := gateway.NewTestSession(66001), gateway.NewTestSession(66002)
	noteMonsterListCaps(old, []byte{MonsterListFlagPaged})
	noteMonsterListCaps(asked, []byte{MonsterListFlagPaged | MonsterListFlagParty})
	for _, c := range []struct {
		sess  *gateway.Session
		party bool
		word  uint32
	}{{old, false, 1}, {asked, true, 0x101}} {
		snap := monsterSnapshotFor(c.sess, *m)
		data := snap.Encode()
		word := uint32(data[len(data)-4]) | uint32(data[len(data)-3])<<8
		back, _, err := decodeMonsterSnapshot(data)
		if err != nil {
			t.Fatal(err)
		}
		if word != c.word || back.Party != c.party || back.Rarity != 1 {
			t.Fatalf("party %v: rarity word %#x, decoded %+v; want %#x", c.party, word, back, c.word)
		}
	}
}

// The kill's party count: the killer's party members alive, in the monster's
// zone and within 1000 units of the dead monster; none for a lone killer.
func TestPartyMembersNearTheKill(t *testing.T) {
	hub := world.NewHub()
	parties := party.NewHub()
	sessions := map[int64]*gateway.Session{}
	enter := func(id int64, x float64, life world.LifeState) {
		sess := gateway.NewTestSession(uint64(66100 + id))
		sessions[id] = sess
		hub.Enter(sess, id, "p", 50, "jangan", world.Position{X: x})
		if life == world.LifeDead {
			hub.SetLifeState(id, world.LifeAlive, world.LifeDead, time.Now())
		}
	}
	enter(1, 0, world.LifeAlive)
	enter(2, 900, world.LifeAlive)
	enter(3, 1200, world.LifeAlive)
	enter(4, 10, world.LifeDead)
	m := combat.Monster{ID: 9, Zone: "jangan", X: 100}
	if partyArmRange != nest.PartyArmRange {
		t.Fatalf("session's range %v is not nest.PartyArmRange %v", partyArmRange, nest.PartyArmRange)
	}
	if n := partyMembersNear(hub, parties, 1, m); n != 0 {
		t.Fatalf("a killer in no party counted %d", n)
	}
	p, err := parties.Create(party.Member{Session: sessions[1], CharacterID: 1, Name: "a", Level: 50})
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []int64{2, 3, 4} {
		if _, err := parties.Join(p.ID, party.Member{Session: sessions[id], CharacterID: id, Name: "m", Level: 50}); err != nil {
			t.Fatal(err)
		}
	}
	// 1 (100 off) and 2 (800 off) count; 3 is 1100 off; 4 is dead.
	if n := partyMembersNear(hub, parties, 1, m); n != 2 {
		t.Fatalf("counted %d members near the kill, want 2", n)
	}
	var got int
	SetMonsterKillObserver(func(_ combat.Monster, members int) { got = members })
	t.Cleanup(func() { SetMonsterKillObserver(nil) })
	noteMonsterKilled(hub, parties, 1, m)
	if got != 2 {
		t.Fatalf("the observer was told %d", got)
	}
}
