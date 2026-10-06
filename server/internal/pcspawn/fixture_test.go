package pcspawn

import (
	"encoding/hex"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/npcspawn"
)

// The bytes client/scripts/net/user_spawn_test.gd reads (round 737): one
// group body of three records -- Aria (sitting, berserk, two items), an NPC,
// Bram (a job suit, so no guild block) -- one 0x3015 of Aria, and a group
// despawn of both players. The GD test holds the same hex; a change to the
// encoder changes this test first.
const (
	fixtureGroup   = "01030073070000220000006d023b0e000000300e00000705000001000000a86100807a440000604000007f44004000010000400100040100008041000048420000c8420004004172696100000000000000000000000000000000000000000000000000000000000000ffd00700000100007fa861000061440000000000806d44000000010000000100000000000000000000000000c84200020207091b3a0000440000006d02ea2900000df82a00000005000002000000a961000020410000000000d0ee4400c000010000c00100000000008041000096420000c8420004004272616d0000000000000000000000ff"
	fixtureSingle  = "73070000220000006d023b0e000000300e00000705000001000000a86100807a440000604000007f44004000010000400100040100008041000048420000c8420004004172696100000000000000000000000000000000000000000000000000000000000000ff04"
	fixtureDespawn = "0202000100000002000000"
)

func fixtureRecords() (aria, bram Record, npc npcspawn.Record) {
	aria = Record{
		RefObjID: 1907, Scale: 0x22, InventorySize: 109, AvatarSize: 5,
		Items: []Item{{RefItemID: 3643, HasPlus: true}, {RefItemID: 3632, Plus: 7, HasPlus: true}},
		UID:   1, Region: 0x61a8, X: 1002, Y: 3.5, Z: 1020, Angle: 16384, RunFlag: 1,
		Life: 1, Motion: 4, BodyMode: 1, Walk: 16, Run: 50, Param140: 100,
		Name: "Aria", JobState: JobStateNone, Team: TeamNone,
	}
	bram = Record{
		RefObjID: 14875, Scale: 0x44, InventorySize: 109, AvatarSize: 5,
		Items: []Item{{RefItemID: 10730, Plus: 13, HasPlus: true}, {RefItemID: 11000, HasPlus: true}},
		UID:   2, Region: 0x61a9, X: 10, Y: 0, Z: 1910.5, Angle: 49152, RunFlag: 1,
		Life: 1, Walk: 16, Run: 75, Param140: 100,
		Name: "Bram", JobState: 2, Team: TeamNone,
	}
	npc = npcspawn.Record{RefID: 2000, UID: 0x7f000001, Region: 0x61a8, X: 900, Y: 0, Z: 950, Angle: 0, Flags: npcspawn.FlagInteractions, Interact: []byte{7, 9}}
	return
}

func fixtureBytes(t *testing.T) (group []byte, single []byte, despawn []byte) {
	t.Helper()
	aria, bram, npc := fixtureRecords()
	a, err := Append(nil, aria)
	if err != nil {
		t.Fatal(err)
	}
	b, err := Append(nil, bram)
	if err != nil {
		t.Fatal(err)
	}
	var body []byte
	body = append(body, a...)
	body = npcspawn.AppendRecord(body, npc)
	body = append(body, b...)
	frames, err := npcspawn.GroupFrames(npcspawn.GroupSpawn, 3, body, 40)
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range frames {
		group = append(group, f.Data...)
	}
	single = append(append([]byte(nil), a...), 4)
	df, err := npcspawn.DespawnGroup([]uint32{1, 2}, 4052)
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range df {
		despawn = append(despawn, f.Data...)
	}
	return group, single, despawn
}

// TestClientFixture checks the three byte strings the GD test embeds are
// what the encoders write (and prints them), and that they read back here as
// they must there.
func TestClientFixture(t *testing.T) {
	group, single, despawn := fixtureBytes(t)
	t.Logf("GROUP %s", hex.EncodeToString(group))
	t.Logf("SINGLE %s", hex.EncodeToString(single))
	t.Logf("DESPAWN %s", hex.EncodeToString(despawn))
	for name, c := range map[string][2]string{
		"group":   {hex.EncodeToString(group), fixtureGroup},
		"single":  {hex.EncodeToString(single), fixtureSingle},
		"despawn": {hex.EncodeToString(despawn), fixtureDespawn},
	} {
		if c[0] != c[1] {
			t.Errorf("the %s bytes changed: user_spawn_test.gd holds the old ones (update both)", name)
		}
	}
	rest := group[3:]
	d, rest, err := Decode(rest, nil)
	if err != nil || d.Name != "Aria" {
		t.Fatalf("aria %+v %v", d, err)
	}
	n, rest, err := npcspawn.DecodeRecord(rest)
	if err != nil || n.UID != 0x7f000001 {
		t.Fatalf("npc %+v %v", n, err)
	}
	d2, rest, err := Decode(rest, suit{2})
	if err != nil || d2.Name != "Bram" || len(rest) != 0 {
		t.Fatalf("bram %+v rest %d %v", d2, len(rest), err)
	}
}
