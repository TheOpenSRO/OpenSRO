package session

import (
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/avatar"
	"github.com/TheOpenSRO/OpenSRO/server/internal/buff"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
)

// Round 839 lane P: FUN_0059f0e0's re-check for the spirits' skills.

func spiritItem839() *refdata.Item {
	return &refdata.Item{ID: 24405, TypeID1: 3, TypeID2: 1, TypeID3: avatar.TypeDevilSpirit}
}

func spiritRow839(id int64, code string, activity int) *refdata.Skill {
	return &refdata.Skill{ID: id, BasicCode: code, Activity: activity, ReqCastList: "14:1", ReqCastListCount: 1, DuraMs: 600000}
}

func TestSpiritReqHolds839(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	awake := int(now.Unix()) + 60
	over := int(now.Unix()) - 1
	hat := &refdata.Item{ID: 1, TypeID1: 3, TypeID2: 1, TypeID3: avatar.TypeAvatar, TypeID4: avatar.KindHat}
	cases := []struct {
		name string
		held []avatar.Held
		want bool
	}{
		{"empty", nil, false},
		{"awake spirit at 4", []avatar.Held{{Slot: inventory.Slot{Index: 4, Durability: awake}, Item: spiritItem839()}}, true},
		{"spirit whose time is over", []avatar.Held{{Slot: inventory.Slot{Index: 4, Durability: over}, Item: spiritItem839()}}, false},
		{"never woken", []avatar.Held{{Slot: inventory.Slot{Index: 4, Durability: 0}, Item: spiritItem839()}}, false},
		{"awake spirit at another index", []avatar.Held{{Slot: inventory.Slot{Index: 2, Durability: awake}, Item: spiritItem839()}}, false},
		// FUN_00498610 passes any item that is not a 3/1/14 (READ): the
		// engine's quirk, kept.
		{"another avatar at 4", []avatar.Held{{Slot: inventory.Slot{Index: 4}, Item: hat}}, true},
	}
	for _, c := range cases {
		if got := spiritReqHolds(c.held, now); got != c.want {
			t.Errorf("%s: %v, want %v", c.name, got, c.want)
		}
	}
}

func TestBuffReqFails839(t *testing.T) {
	const owner = 839001
	self := buff.Record{OwnerID: owner, CasterID: owner, SkillID: 31142, Activity: 2}
	row := spiritRow839(31142, "SKILL_MALL_NASRUN_ECCENTRICDEMON_01", 2)
	with := gearState{known: true, spirit: true}
	without := gearState{known: true}
	if buffReqFails(self, row, with) {
		t.Error("ended while the spirit holds")
	}
	if !buffReqFails(self, row, without) {
		t.Error("kept with the spirit gone")
	}
	// Cast by another: ctx+0x20 is not 1, the record is passed over.
	other := self
	other.CasterID = owner + 1
	if buffReqFails(other, row, without) {
		t.Error("another's cast ended")
	}
	// A passive (Basic_Activity 0) is not ended (its params toggle; OpenSRO
	// keeps no passive records).
	passive := self
	passive.Activity = 0
	if buffReqFails(passive, spiritRow839(1, "SKILL_X", 0), without) {
		t.Error("a passive ended")
	}
	// The fire shield is spared.
	if buffReqFails(self, spiritRow839(2, "SKILL_CH_FIRE_SHIELD_A_01", 2), without) {
		t.Error("the fire shield ended")
	}
	// A weapon list (round 882: the equipment kinds are walked too): kept
	// with the weapon worn, ended without it.
	weapon := &refdata.Skill{ID: 3, BasicCode: "SKILL_CH_SWORD_X", Activity: 2, ReqCastList: "6:2"}
	if buffReqFails(self, weapon, gearOf(wornKind{slot: equipment.SlotWeapon, typeID3: 6, typeID4: 2})) {
		t.Error("a weapon-list buff ended with its weapon worn")
	}
	if !buffReqFails(self, weapon, without) {
		t.Error("a weapon-list buff kept with no weapon")
	}
	if buffReqFails(self, nil, without) {
		t.Error("a record with no row ended")
	}
}

func TestBuffReqsHoldAllOf839(t *testing.T) {
	reqs := []struct {
		packed string
		all    bool
		spirit bool
		want   bool
	}{
		{"14:1", false, true, true},
		{"14:1", false, false, false},
		{"14:2", false, true, false},     // the case wants value 1 (s:0x59f276)
		{"6:2;14:1", false, false, true}, // ANY: the weapon entry holds
		{"6:2;14:1", true, false, false}, // ALL: the spirit entry fails
		{"6:2;14:1", true, true, true},
	}
	for _, c := range reqs {
		g := gearOf(wornKind{slot: equipment.SlotWeapon, typeID3: 6, typeID4: 2})
		g.spirit = c.spirit
		got := gearReqsHold(combat.ParseCastRequirements(c.packed), c.all, g)
		if got != c.want {
			t.Errorf("%q all=%v spirit=%v: %v, want %v", c.packed, c.all, c.spirit, got, c.want)
		}
	}
}

// startSpiritBuff839 starts row's buff on owner, cast by owner, as a skill
// cast does (the row filed for the re-check).
func startSpiritBuff839(t *testing.T, owner int64, row *refdata.Skill, now time.Time) {
	t.Helper()
	rememberRow(false, owner, row)
	if _, _, refused, _ := buffBooks.Start(owner, buff.Spec{SkillID: row.ID, CasterID: owner, DuraMs: row.DuraMs, Activity: row.Activity}, now); refused != buff.NotRefused {
		t.Fatalf("start %d refused: %v", row.ID, refused)
	}
}

func activeSkills839(owner int64) []int64 {
	var out []int64
	for _, r := range buffBooks.Active(owner) {
		out = append(out, r.SkillID)
	}
	return out
}

// A spirit taken off (0x23) ends its skills' running buffs and nothing
// else; while it is worn and awake the re-check keeps them.
func TestSpiritTakenOffEndsItsBuffs839(t *testing.T) {
	f := newAvatarFixture(t)
	owner := f.c.ID
	t.Cleanup(func() { buffBooks.EndAll(owner); forgetRows(false, owner) })
	now := time.Now()
	if err := f.av.PlaceItemInstance(f.ctx, owner, 4, avSpirit, 1, inventory.Instance{Durability: int(now.Unix() + 3600)}); err != nil {
		t.Fatal(err)
	}
	spiritRow := spiritRow839(31142, "SKILL_MALL_NASRUN_ECCENTRICDEMON_01", 2)
	plainRow := &refdata.Skill{ID: 4321, BasicCode: "SKILL_CH_COLD_GANGGI", Activity: 1, DuraMs: 600000}
	startSpiritBuff839(t, owner, spiritRow, now)
	startSpiritBuff839(t, owner, plainRow, now)

	recheckSpiritBuffsAfterMove(f.ctx, f.d, owner)
	if got := activeSkills839(owner); len(got) != 2 {
		t.Fatalf("worn and awake: running %v, want both", got)
	}
	if _, _, code := f.take(t, 4, 13); code != 0 {
		t.Fatalf("take off refused 0x%x", code)
	}
	recheckSpiritBuffsAfterMove(f.ctx, f.d, owner)
	if got := activeSkills839(owner); len(got) != 1 || got[0] != plainRow.ID {
		t.Fatalf("taken off: running %v, want only %d", got, plainRow.ID)
	}
}

// The expiry while worn ends nothing (s:0x4bbd60 runs no re-check); the next
// avatar move's re-check ends the buff of the spirit whose time is over.
func TestSpiritExpiryLeavesBuffUntilNextMove839(t *testing.T) {
	f := newAvatarFixture(t)
	SetAvatarStore(f.av, f.inv, f.items, nil)
	t.Cleanup(func() { SetAvatarStore(nil, nil, nil, nil) })
	owner := f.c.ID
	t.Cleanup(func() { buffBooks.EndAll(owner); forgetRows(false, owner) })
	now := time.Now()
	ends := int(now.Unix() - 1) // its time just ran out
	if err := f.av.PlaceItemInstance(f.ctx, owner, 4, avSpirit, 1, inventory.Instance{Durability: ends}); err != nil {
		t.Fatal(err)
	}
	row := spiritRow839(36279, "SKILL_MALL_AMALRUN_GODOFMERCY_01", 2)
	startSpiritBuff839(t, owner, row, now)

	spiritExpired(owner, 4, ends)
	if got := activeSkills839(owner); len(got) != 1 {
		t.Fatalf("after the expiry: running %v, want the buff", got)
	}
	// A hat put on is an avatar move: the re-check finds the spirit asleep.
	f.bag(t, avHat)
	if _, _, code := f.put(t, 13, 0); code != 0 {
		t.Fatalf("put on refused 0x%x", code)
	}
	recheckSpiritBuffsAfterMove(f.ctx, f.d, owner)
	if got := activeSkills839(owner); len(got) != 0 {
		t.Fatalf("after the next move: running %v, want none", got)
	}
}
