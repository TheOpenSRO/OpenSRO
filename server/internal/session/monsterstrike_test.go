package session

import (
	"bufio"
	"bytes"
	"context"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/leveldata"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/quest"
	"github.com/OpenSRO/srrevamp/server/internal/skill"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// The client's own fixture (client/scripts/net/combat_test.gd,
// STRIKE_FIXTURE; docs/protocol/monster_ai.md, "srrevamp's own monster
// protocol"): monster 7 strikes character 42 for 200, critical and killing
// (flags 0x05), which leaves it on 76 HP and costs it 25900 experience. The
// server's encoder must produce it byte for byte.
var strikeFixture = []byte{0x07, 0, 0, 0, 0, 0, 0, 0, 0x2a, 0, 0, 0, 0, 0, 0, 0,
	0xc8, 0x00, 0x00, 0x00, 0x05, 0x4c, 0x00, 0x00, 0x00, 0x2c, 0x65, 0, 0, 0, 0, 0, 0}

func TestMonsterAttackedMatchesTheClientFixture(t *testing.T) {
	m := &MonsterAttacked{MonsterID: 7, TargetCharacterID: 42, Damage: 200, Critical: true, TargetDied: true,
		TargetHP: 76, DeathExpLost: 25900}
	got := m.Encode()
	if !bytes.Equal(got, strikeFixture) {
		t.Fatalf("MonsterAttacked.Encode:\n got % x\nwant % x", got, strikeFixture)
	}
	back, err := DecodeMonsterAttacked(got)
	if err != nil || *back != *m {
		t.Fatalf("round trip: %+v, %v", back, err)
	}
	// As the client decodes it: 32 bytes are refused, a 34th is ignored.
	if _, err := DecodeMonsterAttacked(strikeFixture[:32]); err == nil {
		t.Error("a 32-byte MonsterAttacked must be refused")
	}
	if long, err := DecodeMonsterAttacked(append(append([]byte{}, strikeFixture...), 0xff)); err != nil || *long != *m {
		t.Errorf("a 34th byte changed the decode: %+v, %v", long, err)
	}
	// A block is bit 1 with 0 damage (combat_test.gd: "flags 0x02 decode as a
	// block with 0 damage").
	blocked := (&MonsterAttacked{MonsterID: 7, TargetCharacterID: 42, Blocked: true, TargetHP: 100}).Encode()
	if blocked[20] != StrikeBlocked {
		t.Errorf("a block encodes flags %#02x, want %#02x", blocked[20], StrikeBlocked)
	}
}

// 0x007D is the opcode the client listens on (CombatNet.OP_MONSTER_ATTACKED)
// and collides with no other session opcode in the 0x0060..0x007F block.
func TestMonsterAttackedOpcode(t *testing.T) {
	if OpMonsterAttacked != 0x007D {
		t.Fatalf("OpMonsterAttacked = 0x%04X; the client decodes 0x007D", OpMonsterAttacked)
	}
	for _, op := range []uint16{OpAttack, OpAttackResult, OpMonsterDamaged, OpMonsterDied, OpLootDropped,
		OpMonsterList, OpMonsterListResult, OpLevelUp, OpBerserk, OpBerserkResult,
		OpLearnSkill, OpLearnSkillResult, OpUseSkill, OpSkillList, OpSkillListResult,
		OpSkillState, OpSkillStateResult, OpRaiseMastery, OpRaiseMasteryResult,
		OpGroundItemList, OpGroundItemListResult, OpGroundItemSpawned, OpGroundItemRemoved,
		OpGroundItemOwnerReleased, OpPickUp, OpPickUpResult, OpRepair, OpRepairResult,
		OpMonsterMoved, OpMonsterMotionList} {
		if op == OpMonsterAttacked {
			t.Errorf("OpMonsterAttacked collides with 0x%04X", op)
		}
	}
}

// strikePushForTest turns -monster-strike-push on for the rest of the test
// and puts it back when the test ends.
func strikePushForTest(t *testing.T, on bool) {
	t.Helper()
	was := monsterStrikePush.Load()
	SetMonsterStrikePush(on)
	t.Cleanup(func() { SetMonsterStrikePush(was) })
}

// strikeMangyang is a Mangyang with its real attack skill's ReuseDelay, 3000
// ms (combat.Species.AttackReuseMs; round 254), and BCRadius 6 (round 247).
// Its damage in each test is a fixture number.
var strikeMangyang = combat.Species{Name: "Mangyang", CodeName: "MOB_CH_MANGNYANG", RefObjID: 1933, Level: 1,
	BCRadius: 6, AttackReuseMs: 3000}

// strikeClient is one logged-in player's connection.
type strikeClient struct {
	name string
	id   int64
	conn net.Conn
	r    *bufio.Reader
	x, z float64
}

func (c *strikeClient) write(t *testing.T, opcode uint16, data []byte) {
	t.Helper()
	if err := proto.Write(c.conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
		t.Fatalf("%s: Write: %v", c.name, err)
	}
}

func (c *strikeClient) read(t *testing.T) *proto.Packet {
	t.Helper()
	c.conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	p, err := proto.Read(c.r, nil, nil)
	if err != nil {
		t.Fatalf("%s: Read: %v", c.name, err)
	}
	return p
}

// barrier asks for the monster list and returns every packet that arrived
// before its reply. The server handles one connection's requests in order,
// so when it returns, whatever this connection's earlier requests sent is in
// the slice -- and, once another client's barrier has returned, whatever that
// client's earlier requests sent to this one is too.
func (c *strikeClient) barrier(t *testing.T) []*proto.Packet {
	t.Helper()
	c.write(t, OpMonsterList, nil)
	var before []*proto.Packet
	for {
		p := c.read(t)
		if p.Opcode == OpMonsterListResult {
			return before
		}
		before = append(before, p)
	}
}

// attack swings at a monster and returns the result, which must be the very
// next packet, and every packet that followed it up to a barrier.
func (c *strikeClient) attack(t *testing.T, monsterID int64) (*AttackResult, []*proto.Packet) {
	t.Helper()
	c.write(t, OpAttack, (&AttackRequest{CharacterName: c.name, TargetMonsterID: monsterID}).Encode())
	p := c.read(t)
	if p.Opcode != OpAttackResult {
		t.Fatalf("%s: the first packet after OpAttack is %#04x, want the OpAttackResult", c.name, p.Opcode)
	}
	ar, err := DecodeAttackResult(p.Data)
	if err != nil {
		t.Fatalf("%s: DecodeAttackResult: %v", c.name, err)
	}
	if ar.Error != "" {
		t.Fatalf("%s: attack refused: %s", c.name, ar.Error)
	}
	return ar, c.barrier(t)
}

// strikes returns the OpMonsterAttacked pushes among pkts, decoded.
func strikes(t *testing.T, pkts []*proto.Packet) []*MonsterAttacked {
	t.Helper()
	var out []*MonsterAttacked
	for _, p := range pkts {
		if p.Opcode != OpMonsterAttacked {
			continue
		}
		m, err := DecodeMonsterAttacked(p.Data)
		if err != nil {
			t.Fatalf("DecodeMonsterAttacked: %v", err)
		}
		out = append(out, m)
	}
	return out
}

func opcodesOf(pkts []*proto.Packet) []uint16 {
	out := make([]uint16, len(pkts))
	for i, p := range pkts {
		out[i] = p.Opcode
	}
	return out
}

// strikeZone is a gateway over in-memory stores with Aria and Bram in
// jangan and Cyra moved to donwhang. Bram wears a shield that always blocks
// (TestShieldBlocksInCombat's, BlockRatioMin 100).
type strikeZone struct {
	chars              character.Store
	hub                *world.Hub
	monsters           *combat.Hub
	aria, bram, cyra   *strikeClient
	ariaChar, bramChar int64
}

// startStrikeZone starts the zone. Each extra builds one more handler over
// the zone's own stores and hubs, chained after the combat handler (round
// 542's GM /spawn test adds the GM console this way).
func startStrikeZone(t *testing.T, extra ...func(chars character.Store, hub *world.Hub, monsters *combat.Hub) gateway.Handler) *strikeZone {
	t.Helper()
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	accounts.Add("bob", "hunter3")
	accounts.Add("cara", "hunter4")
	chars := character.NewMemStore()
	ids := map[string]int64{}
	for i, name := range []string{"Aria", "Bram", "Cyra"} {
		c, err := chars.Create(ctx, int64(i+1), name)
		if err != nil {
			t.Fatalf("creating %s: %v", name, err)
		}
		ids[name] = c.ID
	}
	items := stubCombatItems{101: {ID: 101, BlockRatioMin: 100}}
	inv := inventory.NewMemStore(items)
	eq := equipment.NewMemStore(inv)
	if err := inv.AddItem(ctx, ids["Bram"], 101, 1); err != nil {
		t.Fatalf("seeding Bram's shield: %v", err)
	}
	if err := eq.Equip(ctx, ids["Bram"], equipment.SlotShield, 0); err != nil {
		t.Fatalf("equipping Bram's shield: %v", err)
	}
	hub := world.NewHub()
	monsters := combat.NewHub()
	handlers := []gateway.Handler{
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		CombatHandler(chars, eq, items, hub, monsters, quest.NewMemStore(), inv, skill.NewMemStore(), nil, nil, nil),
	}
	for _, build := range extra {
		handlers = append(handlers, build(chars, hub, monsters))
	}
	handle := gateway.Chain(handlers...)
	addr, cleanup := startTestServer(t, handle)
	t.Cleanup(cleanup)

	join := func(user, pass, name string) *strikeClient {
		conn := dialTestServer(t, addr)
		t.Cleanup(func() { conn.Close() })
		c := &strikeClient{name: name, id: ids[name], conn: conn, r: bufio.NewReader(conn)}
		c.write(t, OpLogin, (&LoginRequest{Username: user, Password: pass}).Encode())
		if lr, err := DecodeLoginResult(c.read(t).Data); err != nil || !lr.OK {
			t.Fatalf("%s login failed: err=%v result=%+v", user, err, lr)
		}
		c.write(t, OpEnterWorld, (&EnterWorldRequest{CharacterName: name}).Encode())
		ewr, err := DecodeEnterWorldResult(c.read(t).Data)
		if err != nil || !ewr.OK || ewr.Zone != "jangan" {
			t.Fatalf("%s enter world: err=%v result=%+v, want OK in jangan", name, err, ewr)
		}
		c.x, c.z = float64(ewr.X), float64(ewr.Z)
		return c
	}
	z := &strikeZone{chars: chars, hub: hub, monsters: monsters, ariaChar: ids["Aria"], bramChar: ids["Bram"]}
	z.aria = join("alice", "hunter2", "Aria")
	z.bram = join("bob", "hunter3", "Bram")
	z.cyra = join("cara", "hunter4", "Cyra")
	z.cyra.write(t, OpChangeZone, (&ChangeZoneRequest{Zone: "donwhang"}).Encode())
	for {
		p := z.cyra.read(t)
		if p.Opcode != OpChangeZoneResult {
			continue
		}
		if czr, err := DecodeChangeZoneResult(p.Data); err != nil || !czr.OK || czr.Zone != "donwhang" {
			t.Fatalf("Cyra's zone change: err=%v result=%+v", err, czr)
		}
		break
	}
	// Drain the entered/left notices, so each client's next barrier holds
	// only what the test itself caused.
	for _, c := range []*strikeClient{z.aria, z.bram, z.cyra} {
		c.barrier(t)
	}
	return z
}

// THE RED (round 541): Aria and Bram stand in jangan, Cyra in donwhang. Aria
// hits a Mangyang whose counter is ready. With -monster-strike-push on, Bram
// -- in the same zone, not the attacker -- receives exactly one
// OpMonsterAttacked, and so does Aria, right after her OpAttackResult; both
// carry exactly the counter her result reports. Before round 541 nobody
// received 0x007D at all, so Bram's count was 0 and this fails.
//
// CONTROLS (they pass before the change too, since nothing was sent then):
// Cyra in donwhang receives none, and a second blow inside the Mangyang's
// ReuseDelay draws no counter and sends none to anyone.
func TestMonsterCounterReachesTheZone(t *testing.T) {
	strikePushForTest(t, true)
	z := startStrikeZone(t)
	m := z.monsters.SpawnSpecies("jangan", strikeMangyang, z.aria.x, 0, z.aria.z, 1000, 0, 15, 0)

	res, ariaAfter := z.aria.attack(t, m.ID)
	if res.PlayerDamageTaken <= 0 {
		t.Fatalf("precondition: the Mangyang's counter was ready, so the result reports one; got %+v", res)
	}
	bramGot := z.bram.barrier(t)
	cyraGot := z.cyra.barrier(t)

	want := &MonsterAttacked{MonsterID: m.ID, TargetCharacterID: z.ariaChar,
		Damage: res.PlayerDamageTaken, Critical: res.MonsterCritical, Blocked: res.PlayerBlocked,
		TargetDied: res.PlayerDied, TargetHP: res.PlayerHP, DeathExpLost: res.DeathExpLost}

	bramStrikes := strikes(t, bramGot)
	if len(bramStrikes) != 1 {
		t.Fatalf("Bram, in the same zone, received %d OpMonsterAttacked (packets %#04x), want exactly 1",
			len(bramStrikes), opcodesOf(bramGot))
	}
	if *bramStrikes[0] != *want {
		t.Errorf("Bram's push %+v, want the counter Aria's result reports %+v", bramStrikes[0], want)
	}
	// Bram sees the swing's damage first, then the monster's reply.
	if ops := opcodesOf(bramGot); len(ops) != 2 || ops[0] != OpMonsterDamaged || ops[1] != OpMonsterAttacked {
		t.Errorf("Bram received %#04x, want OpMonsterDamaged then OpMonsterAttacked", ops)
	}

	// Aria: the push is the very next packet after her result, and the only one.
	if ops := opcodesOf(ariaAfter); len(ops) != 1 || ops[0] != OpMonsterAttacked {
		t.Fatalf("after her result Aria received %#04x, want exactly one OpMonsterAttacked", ops)
	}
	if got := strikes(t, ariaAfter)[0]; *got != *want {
		t.Errorf("Aria's push %+v, want %+v", got, want)
	}
	if !bytes.Equal(ariaAfter[0].Data, bramStrikes[0].Encode()) {
		t.Errorf("Aria's and Bram's pushes differ: % x / % x", ariaAfter[0].Data, bramStrikes[0].Encode())
	}

	// CONTROL: another zone hears nothing.
	if n := len(strikes(t, cyraGot)); n != 0 {
		t.Errorf("Cyra, in donwhang, received %d OpMonsterAttacked, want 0", n)
	}

	// CONTROL: inside the 3000 ms ReuseDelay the Mangyang cannot strike, so
	// there is no counter and no push.
	res2, ariaAfter2 := z.aria.attack(t, m.ID)
	if res2.PlayerDamageTaken != 0 || res2.PlayerBlocked {
		t.Fatalf("precondition: a blow inside the ReuseDelay draws no counter; got %+v", res2)
	}
	if n := len(strikes(t, ariaAfter2)); n != 0 {
		t.Errorf("Aria received %d OpMonsterAttacked for a blow with no counter, want 0", n)
	}
	for _, c := range []*strikeClient{z.bram, z.cyra} {
		if n := len(strikes(t, c.barrier(t))); n != 0 {
			t.Errorf("%s received %d OpMonsterAttacked for a blow with no counter, want 0", c.name, n)
		}
	}
}

// The flags reach the zone as the result reports them. Aria, level 11 with
// experience banked, is killed by a critical counter: the push to Bram
// carries bit 0 and bit 2 (0x05), the HP she was put back on her feet with
// and the experience the death cost. Bram's shield then blocks a counter:
// the push to Aria carries bit 1 and 0 damage, on Bram.
func TestMonsterStrikePushCarriesTheFlags(t *testing.T) {
	strikePushForTest(t, true)
	// TestDeathPenaltyAppliedInCombat's table: level 11's EXP unit is 259.
	tbl, err := leveldata.ParseCSV(strings.NewReader("level,exp,mastery_sp,exp_unit\n10,23500,9,235\n11,34898,12,259\n"))
	if err != nil {
		t.Fatalf("ParseCSV: %v", err)
	}
	SetLevelTable(tbl)
	t.Cleanup(func() { SetLevelTable(nil) })

	z := startStrikeZone(t)
	if err := z.chars.SetLeveling(context.Background(), z.ariaChar, 11, 30000, 0, character.StartingStr, character.StartingInt); err != nil {
		t.Fatalf("setting Aria's level: %v", err)
	}
	killer := strikeMangyang
	killer.Critical = 100 // a certainty, as in TestMonsterCriticalAppliedInCombat
	k := z.monsters.SpawnSpecies("jangan", killer, z.aria.x, 0, z.aria.z, 100000, 0, 100000, 0)

	res, ariaAfter := z.aria.attack(t, k.ID)
	// exp_unit(11) * 100, as TestDeathPenaltyAppliedInCombat pins it.
	if !res.PlayerDied || !res.MonsterCritical || res.DeathExpLost != 259*leveldata.DeathPenaltyKilledByMonster {
		t.Fatalf("precondition: a killing critical costing 259 * 100 experience; got %+v", res)
	}
	bramStrikes := strikes(t, z.bram.barrier(t))
	if len(bramStrikes) != 1 {
		t.Fatalf("Bram received %d OpMonsterAttacked, want 1", len(bramStrikes))
	}
	got := bramStrikes[0]
	want := &MonsterAttacked{MonsterID: k.ID, TargetCharacterID: z.ariaChar, Damage: res.PlayerDamageTaken,
		Critical: true, TargetDied: true, TargetHP: res.PlayerHP, DeathExpLost: res.DeathExpLost}
	if *got != *want {
		t.Errorf("the killing push %+v, want %+v", got, want)
	}
	if ops := opcodesOf(ariaAfter); len(ops) != 1 || ops[0] != OpMonsterAttacked {
		t.Fatalf("after her result Aria received %#04x, want exactly one OpMonsterAttacked", ops)
	}
	if flags := ariaAfter[0].Data[20]; flags != StrikeCritical|StrikeTargetDied {
		t.Errorf("the killing push's flags %#02x, want 0x05", flags)
	}

	b := z.monsters.SpawnSpecies("jangan", strikeMangyang, z.bram.x, 0, z.bram.z, 1000, 0, 15, 0)
	bres, _ := z.bram.attack(t, b.ID)
	if !bres.PlayerBlocked || bres.PlayerDamageTaken != 0 {
		t.Fatalf("precondition: Bram's shield blocks the counter; got %+v", bres)
	}
	ariaStrikes := strikes(t, z.aria.barrier(t))
	if len(ariaStrikes) != 1 {
		t.Fatalf("Aria received %d OpMonsterAttacked for Bram's blocked counter, want 1", len(ariaStrikes))
	}
	wantBlock := MonsterAttacked{MonsterID: b.ID, TargetCharacterID: z.bramChar, Blocked: true, TargetHP: bres.PlayerHP}
	if *ariaStrikes[0] != wantBlock {
		t.Errorf("the blocked push %+v, want %+v", ariaStrikes[0], wantBlock)
	}
}

// CONTROL, the default: with -monster-strike-push off the wire is what it
// was before round 541. The attacker gets her result and nothing after it,
// the zone gets OpMonsterDamaged and nothing else, and the result still
// carries the counter.
func TestMonsterStrikePushOffIsTheOldWire(t *testing.T) {
	strikePushForTest(t, false)
	z := startStrikeZone(t)
	m := z.monsters.SpawnSpecies("jangan", strikeMangyang, z.aria.x, 0, z.aria.z, 1000, 0, 15, 0)

	res, ariaAfter := z.aria.attack(t, m.ID)
	if res.PlayerDamageTaken != 15 || res.PlayerHP != int32(character.StartingMaxHP)-15 {
		t.Fatalf("the counter in the result: got %+v, want 15 taken and %d HP", res, character.StartingMaxHP-15)
	}
	if len(ariaAfter) != 0 {
		t.Errorf("after her result Aria received %#04x, want nothing", opcodesOf(ariaAfter))
	}
	if ops := opcodesOf(z.bram.barrier(t)); len(ops) != 1 || ops[0] != OpMonsterDamaged {
		t.Errorf("Bram received %#04x, want only OpMonsterDamaged", ops)
	}
	if got := z.cyra.barrier(t); len(got) != 0 {
		t.Errorf("Cyra received %#04x, want nothing", opcodesOf(got))
	}
}
