package session

import (
	"encoding/binary"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/cos"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/grounditem"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
)

// Round 805: a COS HP potion lands on the pet the use names (the client's
// current COS, sent as UseOptionCOSTarget + the uid), is refused with no pet
// named, and holds its kind's 1.1 s reuse lock (s:0x49d240).
func TestRound805COSPotion(t *testing.T) {
	clock := time.Unix(1_800_000_000, 0)
	saved := useItemClock
	t.Cleanup(func() { useItemClock = saved })
	useItemClock = func() time.Time { return clock }

	rig := newCOSRig(t, 7)
	_, got := rig.use(fxTigerScroll)
	acks := got[cos.OpCOSRideAck]
	if len(acks) == 0 {
		t.Fatal("no ride")
	}
	uid := binary.LittleEndian.Uint32(acks[0][6:])
	o := cosWorld.get(uid)
	cosWorld.mu.Lock()
	o.rec.HP = 100
	maxHP := o.row.MaxHP
	cosWorld.mu.Unlock()

	useOn := func(target uint32) (*UseItemResult, map[uint16][][]byte) {
		t.Helper()
		data := clientUse("Aria", rig.slot(fxCOSPotion).Index, 0, 0)
		if target != 0 {
			data = append(data, UseOptionCOSTarget)
			data = binary.LittleEndian.AppendUint32(data, target)
		}
		rig.send(OpUseItem, data)
		res, err := DecodeUseItemResult(rig.until(OpUseItemResult).Data)
		if err != nil {
			t.Fatal(err)
		}
		return res, rig.drain()
	}
	hpOf := func(got map[uint16][][]byte) int {
		for _, st := range got[OpObjectStatus] {
			if st[0] == OwnerCOS && binary.LittleEndian.Uint64(st[1:]) == uint64(uid) {
				return int(binary.LittleEndian.Uint32(st[12:]))
			}
		}
		return -1
	}

	// No pet named: COSPETERR_CANT_USEITEM, nothing spent.
	if res, _ := useOn(0); res.Code != cos.ErrPetCantUseItem {
		t.Fatalf("a use naming no pet: %+v, want 0x%x", res, cos.ErrPetCantUseItem)
	}
	// Named: healed, one spent.
	res, got := useOn(uid)
	if res.Error != "" || res.Remaining != 4 {
		t.Fatalf("the potion on the tiger: %+v", res)
	}
	hp := hpOf(got)
	if hp <= 100 || hp > maxHP {
		t.Fatalf("the tiger's HP push after the potion: %d (from 100, max %d)", hp, maxHP)
	}
	cosWorld.mu.Lock()
	held := o.rec.HP
	cosWorld.mu.Unlock()
	if held != hp {
		t.Fatalf("server HP %d, pushed %d", held, hp)
	}
	// Inside 1.1 s: WAIT_FOR_REUSE_DELAY, the potion kept.
	clock = clock.Add(time.Second)
	if res, _ := useOn(uid); res.Error != reuseDelayRefusal {
		t.Fatalf("a second potion 1 s later: %+v, want the reuse refusal", res)
	}
	if n := rig.slot(fxCOSPotion).Quantity; n != 4 {
		t.Fatalf("a refused potion was spent: %d left", n)
	}
	// Past it: used again.
	clock = clock.Add(200 * time.Millisecond)
	if res, _ := useOn(uid); res.Error != "" || res.Remaining != 3 {
		t.Fatalf("a potion 1.2 s later: %+v", res)
	}
}

// Round 805: a dropped trade good carries its instance's name string (the
// buyer's alias) to the client, after the fixed snapshot, so a reader that
// walks fixed snapshots still reads both packets.
func TestRound805GroundItemCreator(t *testing.T) {
	now := time.Now()
	good := snapshotOf(grounditem.Item{ID: 9, ItemID: 7, Quantity: 100, X: 1, Y: 2, Z: 3,
		Instance: &inventory.Instance{Durability: -1, Creator: "Merchy"}}, now)
	plain := snapshotOf(grounditem.Item{ID: 10, ItemID: 8, Quantity: 1}, now)
	if good.Creator != "Merchy" || plain.Creator != "" {
		t.Fatalf("snapshots: %q %q", good.Creator, plain.Creator)
	}
	data := good.EncodeSpawned()
	got, err := DecodeGroundItemSpawned(data)
	if err != nil || got.Creator != "Merchy" || got.ID != 9 || got.Quantity != 100 {
		t.Fatalf("spawned: %+v %v", got, err)
	}
	if old, rest, err := decodeGroundItemSnapshot(data); err != nil || old.ID != 9 || len(rest) != 2+len("Merchy") {
		t.Fatalf("a fixed-snapshot reader: %+v rest %d %v", old, len(rest), err)
	}
	if got, err := DecodeGroundItemSpawned(good.Encode()); err != nil || got.Creator != "" {
		t.Fatalf("a pre-805 spawn: %+v %v", got, err)
	}
	list := (&GroundItemListResult{Items: []GroundItemSnapshot{plain, good}}).Encode()
	lr, err := DecodeGroundItemListResult(list)
	if err != nil || len(lr.Items) != 2 || lr.Items[0].Creator != "" || lr.Items[1].Creator != "Merchy" {
		t.Fatalf("list: %+v %v", lr, err)
	}
}

// Round 805: a monster's body byte (rand() & 0xff at creation, the NPC
// thief's and hunter's dressing) rides in the rarity word's third byte with
// MonsterRarityBodyBit, only to a session whose list request carried
// MonsterListFlagBody; the rank and the party flag stay where they were.
func TestRound805MonsterBodyOnTheWire(t *testing.T) {
	monsters := combat.NewHub()
	m := monsters.SpawnHatched("jangan", combat.Species{Name: "Thief", CodeName: "MOB_THIEF_NPC_0001", Rarity: 1, Level: 1},
		5, 0, 6, 100, 1, 1, 0, combat.Hatch{HomeX: 5, HomeZ: 6, Party: true})
	m.Body = 0xa7
	old, asked := gateway.NewTestSession(80501), gateway.NewTestSession(80502)
	noteMonsterListCaps(old, []byte{MonsterListFlagPaged | MonsterListFlagParty})
	noteMonsterListCaps(asked, []byte{MonsterListFlagPaged | MonsterListFlagParty | MonsterListFlagBody})
	for _, c := range []struct {
		sess *gateway.Session
		body bool
		word uint32
	}{{old, false, 0x101}, {asked, true, 0xa70301}} {
		snap := monsterSnapshotFor(c.sess, *m)
		data := snap.Encode()
		word := binary.LittleEndian.Uint32(data[len(data)-4:])
		back, _, err := decodeMonsterSnapshot(data)
		if err != nil {
			t.Fatal(err)
		}
		if word != c.word || back.HasBody != c.body || back.Rarity != 1 || !back.Party || (c.body && back.Body != 0xa7) {
			t.Fatalf("body %v: rarity word %#x, decoded %+v; want %#x", c.body, word, back, c.word)
		}
	}
	// Every monster draws its own byte: 64 spawns are not all one value.
	seen := map[byte]bool{}
	for i := 0; i < 64; i++ {
		seen[monsters.Spawn("jangan", "x", 0, 0, 0, 10, 1, 1, 0).Body] = true
	}
	if len(seen) < 2 {
		t.Fatalf("64 spawns drew %d body value(s)", len(seen))
	}
}
