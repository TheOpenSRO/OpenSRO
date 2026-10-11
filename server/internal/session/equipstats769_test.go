package session

import (
	"bufio"
	"context"
	"math"
	"strings"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/magicopt"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
)

// Round 769: a worn item's plus and blue options count. One character wears
// a +3 sword (STR 5, critical 2, attack rate +50 %), a +2 mail (parry +25 %,
// HP 100) and a shield (block 3, evade critical 20).
func TestWornPlusAndOptionsCount(t *testing.T) {
	ctx := context.Background()
	tbl, err := magicopt.LoadCSV(strings.NewReader(strings.Join([]string{
		"10,MATTR_STR,1,1,7566450,65538,196608,0,0,weapon|armor|shield|accessory",
		"11,MATTR_HP,1,1,26736,65538,0,0,0,armor",
		"12,MATTR_CRITICAL,1,1,6517353,65538,0,0,0,weapon",
		"13,MATTR_ER,1,1,25970,65538,0,0,0,armor",
		"14,MATTR_HR,1,1,26738,65538,0,0,0,weapon",
		"15,MATTR_BLOCKRATE,1,1,6451817,65538,0,0,0,shield",
		"16,MATTR_EVADE_CRITICAL,1,1,1702257522,65538,0,0,0,shield",
	}, "\n") + "\n"))
	if err != nil {
		t.Fatal(err)
	}
	SetMagicOptions(tbl)
	t.Cleanup(func() { SetMagicOptions(nil); character.SetBonusSource(nil) })

	items := refdata.NewMemStore()
	eqp := func(id int64) refdata.Item {
		return refdata.Item{ID: id, MaxStack: 1, DurabilityMin: 10, DurabilityMax: 10,
			TypeID1: equipment.TypeItem, TypeID2: equipment.TypeEquipment, Country: equipment.CountryChina}
	}
	sword, mail, shield := eqp(100), eqp(200), eqp(300)
	sword.TypeID3, sword.TypeID4 = 6, 2
	sword.PhysAttackMin, sword.PhysAttackMax, sword.PlusIncPhysAtk = 6, 9, 2.4
	sword.HitRateMin, sword.HitRateMax = 24, 24
	sword.CriticalMin, sword.CriticalMax = 3, 3
	mail.TypeID3, mail.TypeID4 = 1, 3
	mail.PhysDefenseMin, mail.PhysDefenseMax, mail.PlusIncPhysDef = 10, 10, 1
	mail.ParryRatioMin, mail.ParryRatioMax = 4, 4
	shield.TypeID3, shield.TypeID4 = 4, 1
	shield.BlockRatioMin, shield.BlockRatioMax = 10, 10
	if err := items.ImportItems(ctx, []refdata.Item{sword, mail, shield}); err != nil {
		t.Fatal(err)
	}
	inv := inventory.NewMemStore(items)
	eq := equipment.NewMemStore(inv)
	wear := func(id int64, slot equipment.Slot, plus uint8, opts ...uint64) {
		t.Helper()
		if err := inv.AddItemInstance(ctx, 1, id, 1, inventory.Instance{Durability: 10, OptLevel: plus, MagParams: opts}); err != nil {
			t.Fatal(err)
		}
		if err := eq.Equip(ctx, 1, slot, 0); err != nil {
			t.Fatal(err)
		}
	}
	wear(100, equipment.SlotWeapon, 3, inventory.MagParam(10, 5), inventory.MagParam(12, 2), inventory.MagParam(14, 50))
	wear(200, equipment.SlotMail, 2, inventory.MagParam(13, 25), inventory.MagParam(11, 100))
	wear(300, equipment.SlotShield, 0, inventory.MagParam(15, 3), inventory.MagParam(16, 20))
	SetEquipBonusSource(eq)

	c := &character.Character{ID: 1, Level: 2, HP: 10, Str: 20, Int: 20}
	got, err := buildCharacterStats(ctx, c, 1, eq, items, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if got.Str != 25 || got.Int != 20 {
		t.Errorf("Str/Int %d/%d, want 25/20 (the STR option in)", got.Str, got.Int)
	}
	if want := character.MaxHPFor(25, 2) + 100; int(got.MaxHP) != want {
		t.Errorf("MaxHP %d, want %d (the chain at STR 25, plus HP 100)", got.MaxHP, want)
	}
	// 6 + 2.4*3 = 13.2 and 9 + 7.2 = 16.2, each rounded.
	if got.PhysAttackMin != 13 || got.PhysAttack != 16 {
		t.Errorf("phys attack %d~%d, want 13~16 (the plus on both ends)", got.PhysAttackMin, got.PhysAttack)
	}
	if got.PhysDefense != 12 {
		t.Errorf("phys defence %d, want 12 (10 + 1 x +2)", got.PhysDefense)
	}
	// 10 + level 2 + 24 * 1.5; 10 + 2 + 4 * 1.25.
	if got.HitRate != 48 || got.ParryRate != int32(math.Round(17)) {
		t.Errorf("hit/parry %d/%d, want 48/17", got.HitRate, got.ParryRate)
	}
	if cr := attackerCritical(ctx, 1, eq, items); cr != 5 {
		t.Errorf("critical %d, want 3 + 2", cr)
	}
	if bl := defenderBlock(ctx, 1, eq, items); bl != 13 {
		t.Errorf("block %d, want 10 + 3", bl)
	}
	if ev := playerEvadeCrit(ctx, 1, eq); ev != 20 {
		t.Errorf("evade critical %v, want 20", ev)
	}
	// Taking the mail off, and the bonus cleared as the handler clears it,
	// drops its HP.
	if err := eq.Unequip(ctx, 1, equipment.SlotMail); err != nil {
		t.Fatal(err)
	}
	character.InvalidateBonus(1)
	if want := character.MaxHPFor(25, 2); c.MaxHP() != want {
		t.Errorf("MaxHP after the mail is off %d, want %d", c.MaxHP(), want)
	}
}

// The cases the first test left out (round 769's review F8): the weapon's
// critical through variance group 6, a 'rein' option in the plus, a broken
// piece counting nothing, the 'int' / 'mp' / 'evbl' options, and the magical
// defence's plus.
func TestWornOptionsTheRestOfTheRules(t *testing.T) {
	ctx := context.Background()
	tbl, err := magicopt.LoadCSV(strings.NewReader(strings.Join([]string{
		"20,MATTR_INT,1,1,6909556,65538,0,0,0,weapon|armor",
		"21,MATTR_MP,1,1,28016,65538,0,0,0,armor",
		"22,MATTR_EVADE_BLOCK,1,1,1702257260,65538,0,0,0,weapon",
		"23,MATTR_REINFORCE_ITEM,2,1,1919248750,0,2,0,0,weapon",
		"24,MATTR_HP,1,1,26736,65538,0,0,0,armor",
	}, "\n") + "\n"))
	if err != nil {
		t.Fatal(err)
	}
	SetMagicOptions(tbl)
	t.Cleanup(func() { SetMagicOptions(nil); character.SetBonusSource(nil) })
	items := refdata.NewMemStore()
	sword := refdata.Item{ID: 100, MaxStack: 1, DurabilityMin: 10, DurabilityMax: 10, TypeID1: 3, TypeID2: 1, TypeID3: 6, TypeID4: 2,
		PhysAttackMin: 10, PhysAttackMax: 10, PlusIncPhysAtk: 1, CriticalMin: 2, CriticalMax: 33}
	mail := refdata.Item{ID: 200, MaxStack: 1, DurabilityMin: 10, DurabilityMax: 10, TypeID1: 3, TypeID2: 1, TypeID3: 1, TypeID4: 3,
		MagDefenseMin: 5, MagDefenseMax: 5, PlusIncMagDef: 2}
	if err := items.ImportItems(ctx, []refdata.Item{sword, mail}); err != nil {
		t.Fatal(err)
	}
	inv := inventory.NewMemStore(items)
	eq := equipment.NewMemStore(inv)
	// The sword: critical group 6 at 31/31, +1 and a level-2 'rein' (col 9 = 2).
	g6 := uint64(31) << (5 * 6)
	if err := inv.AddItemInstance(ctx, 1, 100, 1, inventory.Instance{Durability: 10, Variance: g6, OptLevel: 1,
		MagParams: []uint64{inventory.MagParam(20, 4), inventory.MagParam(22, 30), inventory.MagParam(23, 2)}}); err != nil {
		t.Fatal(err)
	}
	if err := eq.Equip(ctx, 1, equipment.SlotWeapon, 0); err != nil {
		t.Fatal(err)
	}
	if err := inv.AddItemInstance(ctx, 1, 200, 1, inventory.Instance{Durability: 10, OptLevel: 3,
		MagParams: []uint64{inventory.MagParam(21, 50), inventory.MagParam(24, 70)}}); err != nil {
		t.Fatal(err)
	}
	if err := eq.Equip(ctx, 1, equipment.SlotMail, 0); err != nil {
		t.Fatal(err)
	}
	SetEquipBonusSource(eq)
	c := &character.Character{ID: 1, Level: 1, HP: 1, Str: 20, Int: 20}
	got, err := buildCharacterStats(ctx, c, 1, eq, items, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if got.Int != 24 || int(got.MaxMP) != character.MaxMPFor(24, 1)+50 {
		t.Errorf("Int %d MaxMP %d, want 24 and the chain plus 50", got.Int, got.MaxMP)
	}
	// +1 and rein 2: plus 3, so 10 + 3.
	if got.PhysAttackMin != 13 {
		t.Errorf("phys attack min %d, want 13 (+1 and a level-2 rein)", got.PhysAttackMin)
	}
	if got.MagDefense != 11 {
		t.Errorf("mag defence %d, want 5 + 2 x 3", got.MagDefense)
	}
	if cr := attackerCritical(ctx, 1, eq, items); cr != 33 {
		t.Errorf("critical %d, want 33 (group 6 at the top)", cr)
	}
	if ev := playerEvadeBlock(ctx, 1, eq); ev != 30 {
		t.Errorf("evade block %v, want 30", ev)
	}
	// The mail broken: its MP and HP stop counting.
	if err := eq.SetDurability(ctx, 1, equipment.SlotMail, 0); err != nil {
		t.Fatal(err)
	}
	character.InvalidateBonus(1)
	if c.MaxMP() != character.MaxMPFor(24, 1) || c.MaxHP() != character.MaxHPFor(20, 1) {
		t.Errorf("broken mail: MaxMP %d MaxHP %d, want neither carrying its options", c.MaxMP(), c.MaxHP())
	}
}

// A store that cannot be read is not cached as a zero bonus (review F3).
func TestBonusReadFailureIsNotCached(t *testing.T) {
	calls := 0
	character.SetBonusSource(func(id int64) (character.Bonus, bool) {
		calls++
		if calls == 1 {
			return character.Bonus{}, false
		}
		return character.Bonus{Str: 7}, true
	})
	t.Cleanup(func() { character.SetBonusSource(nil) })
	if b := character.BonusOf(42); b.Str != 0 {
		t.Fatalf("first read %+v, want the failed zero", b)
	}
	if b := character.BonusOf(42); b.Str != 7 {
		t.Fatalf("second read %+v, want 7 (the failure was not cached)", b)
	}
	if character.BonusOf(42); calls != 2 {
		t.Fatalf("source called %d times, want 2 (the good read cached)", calls)
	}
}

// The unequip handler clears the bonus and clamps the stored HP (review F2,
// F8): through the real handler, not a hand-made invalidation.
func TestUnequipClampsHPThroughTheHandler(t *testing.T) {
	ctx := context.Background()
	tbl, err := magicopt.LoadCSV(strings.NewReader("24,MATTR_HP,1,1,26736,65538,0,0,0,armor\n"))
	if err != nil {
		t.Fatal(err)
	}
	SetMagicOptions(tbl)
	t.Cleanup(func() { SetMagicOptions(nil); character.SetBonusSource(nil) })
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	items := refdata.NewMemStore()
	if err := items.ImportItems(ctx, []refdata.Item{{ID: 200, MaxStack: 1, DurabilityMin: 10, DurabilityMax: 10,
		TypeID1: 3, TypeID2: 1, TypeID3: 1, TypeID4: 3}}); err != nil {
		t.Fatal(err)
	}
	inv := inventory.NewMemStore(items)
	eq := equipment.NewMemStore(inv)
	if err := inv.AddItemInstance(ctx, c.ID, 200, 1, inventory.Instance{Durability: 10, MagParams: []uint64{inventory.MagParam(24, 500)}}); err != nil {
		t.Fatal(err)
	}
	if err := eq.Equip(ctx, c.ID, equipment.SlotMail, 0); err != nil {
		t.Fatal(err)
	}
	SetEquipBonusSource(eq)
	if err := chars.ResetHP(ctx, c.ID); err != nil {
		t.Fatal(err)
	}
	full, _ := chars.GetByID(ctx, c.ID)
	if full.HP != full.MaxHP() || full.MaxHP() <= character.MaxHPFor(full.Str, full.Level) {
		t.Fatalf("HP %d max %d: the mail's HP option should be in the max", full.HP, full.MaxHP())
	}
	handle := gateway.Chain(LoginHandler(accounts), EquipmentHandler(chars, eq))
	addr, cleanup := startTestServer(t, handle)
	t.Cleanup(cleanup)
	conn := dialTestServer(t, addr)
	t.Cleanup(func() { conn.Close() })
	r := bufio.NewReader(conn)
	send := func(op uint16, data []byte) *proto.Packet {
		t.Helper()
		if err := proto.Write(conn, &proto.Packet{Opcode: op, Data: data}, nil, nil); err != nil {
			t.Fatal(err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		p, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatal(err)
		}
		return p
	}
	if lr, err := DecodeLoginResult(send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode()).Data); err != nil || !lr.OK {
		t.Fatalf("login: %v %+v", err, lr)
	}
	res, err := DecodeEquipmentResult(send(OpUnequip, (&UnequipRequest{CharacterName: "Aria", Slot: equipment.SlotMail}).Encode()).Data)
	if err != nil || res.Error != "" {
		t.Fatalf("unequip: %v %+v", err, res)
	}
	after, _ := chars.GetByID(ctx, c.ID)
	if want := character.MaxHPFor(after.Str, after.Level); after.MaxHP() != want || after.HP != want {
		t.Fatalf("after the unequip: HP %d max %d, want both %d", after.HP, after.MaxHP(), want)
	}
}
