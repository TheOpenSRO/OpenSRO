package session

import (
	"context"
	"encoding/binary"
	"strings"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/leveldata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
)

// Round 859: a character's level-up is told to everyone in view with retail's
// 0x3054 {u32 its id} (GObjPC_SetLevel s:0x4e4d90), the character itself
// first among them and before its own OpLevelUp; a character that did not
// level sends none.
func TestLevelUpAnnouncedToViewers(t *testing.T) {
	tbl, err := leveldata.ParseCSV(strings.NewReader("level,exp,mastery_sp,exp_unit\n" +
		"7,50,1,200\n8,100000000,1,220\n10,100000000,1,300\n"))
	if err != nil {
		t.Fatal(err)
	}
	prev := levelTable
	SetLevelTable(tbl)
	t.Cleanup(func() { SetLevelTable(prev) })

	w := newPartyWorld(t)
	w.form(t, "Aria", "Bram", party.FlagExpShare)
	w.move(t, "Aria", 10, 10)
	w.move(t, "Bram", 20, 10)
	w.move(t, "Cato", 30, 10)

	m := combat.Monster{ID: 4321, Zone: "jangan", Level: 10, MaxHP: 100, ExpToGive: 300, HasExpToGive: true}
	hits := []combat.Hit{{AttackerID: w.ids["Aria"], Damage: 100}}
	deps := combatDeps{chars: w.chars, hub: w.hub, parties: w.parties}
	if _, err := distributeKill(context.Background(), deps, w.ids["Aria"], m, hits); err != nil {
		t.Fatal(err)
	}

	// Bram: 0x3054 naming Bram, then OpLevelUp.
	var seen []uint16
	var effect *proto.Packet
	for {
		w.c["Bram"].conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		p, err := proto.Read(w.c["Bram"].r, nil, nil)
		if err != nil {
			t.Fatalf("Bram: waiting for OpLevelUp after %x: %v", seen, err)
		}
		seen = append(seen, p.Opcode)
		if p.Opcode == OpLevelUpEffect && effect == nil {
			effect = p
		}
		if p.Opcode == OpLevelUp {
			break
		}
	}
	if effect == nil {
		t.Fatalf("Bram's messages %x: no 0x3054 before OpLevelUp", seen)
	}
	if len(effect.Data) != 4 || int64(binary.LittleEndian.Uint32(effect.Data)) != w.ids["Bram"] {
		t.Errorf("0x3054 % x, want Bram's id %d", effect.Data, w.ids["Bram"])
	}

	// The others in view hear Bram's level-up too.
	for _, who := range []string{"Aria", "Cato"} {
		p := w.c[who].next(OpLevelUpEffect)
		if int64(binary.LittleEndian.Uint32(p.Data)) != w.ids["Bram"] {
			t.Errorf("%s's 0x3054 names %d, want Bram %d", who, binary.LittleEndian.Uint32(p.Data), w.ids["Bram"])
		}
	}
	// Aria's share did not level her: nobody is told of hers.
	w.c["Cato"].none(OpLevelUpEffect)
}

func TestLevelUpEffectPayload(t *testing.T) {
	if got := LevelUpEffect(0x01020304); string(got) != "\x04\x03\x02\x01" {
		t.Errorf("LevelUpEffect = % x", got)
	}
	announceLevelUp(nil, 1) // no hub: nothing, no panic
}
