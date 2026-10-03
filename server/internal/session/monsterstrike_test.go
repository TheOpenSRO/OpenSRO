package session

import (
	"bufio"
	"bytes"
	"context"
	"math"
	"math/rand"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/ai"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/leveldata"
	"github.com/OpenSRO/OpenSRO/server/internal/mana"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/quest"
	"github.com/OpenSRO/OpenSRO/server/internal/skill"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// The client's own fixture (client/scripts/net/combat_test.gd,
// STRIKE_FIXTURE; docs/protocol/monster_ai.md, "OpenSRO's own monster
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

// readUntil reads packets for up to d and returns them all, up to and
// including the first whose opcode is want; nil for that one when the deadline
// passes first. Packets are a few dozen bytes on a local socket, so a
// deadline mid-packet is not a practical risk at these durations.
func (c *strikeClient) readUntil(t *testing.T, want uint16, d time.Duration) ([]*proto.Packet, *proto.Packet) {
	t.Helper()
	var got []*proto.Packet
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		c.conn.SetReadDeadline(deadline)
		p, err := proto.Read(c.r, nil, nil)
		if err != nil {
			return got, nil
		}
		got = append(got, p)
		if p.Opcode == want {
			return got, p
		}
	}
	return got, nil
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
	inv                inventory.Store
	eq                 equipment.Store
	items              stubCombatItems
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
	// 101 is Bram's shield; 102 a bow, Range 180 (itemdata col 94, the retail
	// bow's), which round 546's TestBowShotIsNotAnsweredAtRange hands Aria.
	items := stubCombatItems{101: {ID: 101, BlockRatioMin: 100}, 102: {ID: 102, PhysAttackMax: 30, Range: 180}}
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
	z := &strikeZone{chars: chars, inv: inv, eq: eq, items: items, hub: hub, monsters: monsters, ariaChar: ids["Aria"], bramChar: ids["Bram"]}
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
	// Then, the flag being off, the respawn's move to her return point
	// (round 665, returnAfterKill): after the push, never before it.
	if ops := opcodesOf(ariaAfter); len(ops) != 2 || ops[0] != OpMonsterAttacked || ops[1] != OpChangeZoneResult {
		t.Fatalf("after her result Aria received %#04x, want one OpMonsterAttacked and then the OpChangeZoneResult to her return point", ops)
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

// The control for the counter path with -monster-strike-push ON (round 544).
// The nine tests that swing at a monster whose counter is ready and read one
// reply per request -- combat_test.go's six (TestCombatFullFlow,
// TestCombatArmorMitigation, TestLevelAdvantageAppliedInCombat,
// TestDeathPenaltyAppliedInCombat, TestMonsterCriticalAppliedInCombat,
// TestShieldBlocksInCombat), TestHwanIsEarnedOnTheKillingBlow,
// TestAttackResultNeverReportsZeroHealthForALivingPlayer and TestSkillFullFlow
// -- run at the top level with the flag at its default, off, the public
// server's wire. Here they run again with it on, so the OpMonsterAttacked that
// then follows each counter has to be skipped by every reader (readReply).
// Measured before this round, with the atomic's default flipped in a scratch
// edit: the whole package failed in exactly the last three, each decoding the
// first counter's push as its next reply. The flag goes back to what it was
// when the test ends (strikePushForTest). The subtests run in order, on the
// one test database the nine share; each takes about 0.15 s.
func TestCounterTestsHoldWithTheStrikePushOn(t *testing.T) {
	strikePushForTest(t, true)
	for _, tc := range []struct {
		name string
		run  func(*testing.T)
	}{
		{"TestCombatFullFlow", TestCombatFullFlow},
		{"TestCombatArmorMitigation", TestCombatArmorMitigation},
		{"TestLevelAdvantageAppliedInCombat", TestLevelAdvantageAppliedInCombat},
		{"TestDeathPenaltyAppliedInCombat", TestDeathPenaltyAppliedInCombat},
		{"TestMonsterCriticalAppliedInCombat", TestMonsterCriticalAppliedInCombat},
		{"TestShieldBlocksInCombat", TestShieldBlocksInCombat},
		{"TestHwanIsEarnedOnTheKillingBlow", TestHwanIsEarnedOnTheKillingBlow},
		{"TestAttackResultNeverReportsZeroHealthForALivingPlayer", TestAttackResultNeverReportsZeroHealthForALivingPlayer},
		{"TestSkillFullFlow", TestSkillFullFlow},
	} {
		if !monsterStrikePush.Load() {
			t.Fatalf("the strike push went off before %s", tc.name)
		}
		t.Run(tc.name, tc.run)
	}
}

// The push's recipients are the swing's OpMonsterDamaged recipients plus the
// attacker, off the one zone snapshot performAttack took (round 544): the
// attacker's own session first, then the entities performAttack collected as
// `others`. Called directly with the zone's server-side sessions, which the
// world hub holds: Aria as the attacker and Bram as the one other. Cyra -- in
// the hub, not among the others -- receives nothing, and an entity that is
// the attacker's own session is not sent a second copy. Off, nothing is sent
// to anyone.
func TestStrikePushRecipientsAreTheDamagedRecipientsPlusTheAttacker(t *testing.T) {
	z := startStrikeZone(t)
	aria, ok := z.hub.EntityByCharacterID(z.ariaChar)
	bram, ok2 := z.hub.EntityByCharacterID(z.bramChar)
	if !ok || !ok2 || aria.Session == nil || bram.Session == nil {
		t.Fatalf("the world hub holds Aria (%v) and Bram (%v) with their sessions", ok, ok2)
	}
	msg := &MonsterAttacked{MonsterID: 7, TargetCharacterID: z.ariaChar, Damage: 12, TargetHP: 88}

	strikePushForTest(t, true)
	pushMonsterStrike(aria.Session, []world.Entity{bram, aria}, msg)
	for _, c := range []*strikeClient{z.aria, z.bram} {
		got := strikes(t, c.barrier(t))
		if len(got) != 1 || *got[0] != *msg {
			t.Errorf("%s received %d OpMonsterAttacked %+v, want exactly one equal to %+v", c.name, len(got), got, msg)
		}
	}
	if got := z.cyra.barrier(t); len(got) != 0 {
		t.Errorf("Cyra, not among the swing's others, received %#04x, want nothing", opcodesOf(got))
	}

	// CONTROL, the default: off, the same call sends nothing.
	SetMonsterStrikePush(false)
	pushMonsterStrike(aria.Session, []world.Entity{bram}, msg)
	for _, c := range []*strikeClient{z.aria, z.bram, z.cyra} {
		if got := c.barrier(t); len(got) != 0 {
			t.Errorf("with the push off %s received %#04x, want nothing", c.name, opcodesOf(got))
		}
	}
}

// installMonsterAIForTestWith is installMonsterAIForTest with the runtime's
// configuration -- the stores a monster's own swing needs (round 546).
func installMonsterAIForTestWith(t *testing.T, hub *world.Hub, monsters *combat.Hub, cfg MonsterAIConfig, seed int64, push func(zone string, p *proto.Packet)) *monsterAI {
	t.Helper()
	a := newMonsterAI(hub, monsters, nil, cfg, rand.New(rand.NewSource(seed)), push)
	monsterAIRuntime.Store(a)
	t.Cleanup(func() { monsterAIRuntime.Store(nil) })
	return a
}

// NEGATIVE (round 546), through the real stack: a bow shot from 150 units is
// not answered at range. With -monster-battle on, Aria's OpAttackResult
// carries no counter -- before this round the synchronous counter answered
// every surviving blow at any distance, and nothing read Monster.AttackRange
// -- and nothing reaches anyone as an OpMonsterAttacked until the AI tick has
// chased the Mangyang to its own band, int(dist) <= 12. Then exactly one
// blow, on Aria, reaches Aria and Bram (jangan) and not Cyra (donwhang), and
// Aria's HP is 15 down. Bram's barrier also shows the chase legs Aria's
// swing set off.
func TestBowShotIsNotAnsweredAtRange(t *testing.T) {
	battleForTest(t, true)
	strikePushForTest(t, true)
	z := startStrikeZone(t)
	ctx := context.Background()
	if err := z.inv.AddItem(ctx, z.ariaChar, 102, 1); err != nil {
		t.Fatalf("seeding Aria's bow: %v", err)
	}
	if err := z.eq.Equip(ctx, z.ariaChar, equipment.SlotWeapon, 0); err != nil {
		t.Fatalf("equipping Aria's bow: %v", err)
	}
	m := z.monsters.SpawnSpecies("jangan", chaseMangyang, z.aria.x+150, 0, z.aria.z, 100000, 0, 15, 0)
	a := installMonsterAIForTestWith(t, z.hub, z.monsters,
		MonsterAIConfig{Chars: z.chars, Equipment: z.eq, Items: z.items}, 31, nil) // the real zone broadcast

	res, ariaAfter := z.aria.attack(t, m.ID)
	if res.MonsterDamage <= 0 {
		t.Fatalf("precondition: the bow shot lands from 150 (reach 6+4+180+2); got %+v", res)
	}
	if res.PlayerDamageTaken != 0 || res.PlayerBlocked || res.PlayerHP != int32(character.StartingMaxHP) {
		t.Fatalf("the result answers a blow from 150 units away: %+v; with -monster-battle the monster swings only from its band", res)
	}
	if n := len(strikes(t, ariaAfter)); n != 0 {
		t.Fatalf("Aria received %d OpMonsterAttacked right behind her result, want 0", n)
	}
	if ops := opcodesOf(z.bram.barrier(t)); len(ops) != 1 || ops[0] != OpMonsterDamaged {
		t.Fatalf("Bram received %#04x behind Aria's swing, want only OpMonsterDamaged", ops)
	}

	// The tick: the blow is drained, BATTLE entered, the chase pushed.
	now := aiT0
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	if st := stateOf(t, a, m.ID); st != ai.StateBattle {
		t.Fatalf("state %v after the first tick, want BATTLE", st)
	}
	got, first := z.aria.readUntil(t, OpMonsterMoved, 2*time.Second)
	if first == nil {
		t.Fatalf("no chase leg reached Aria after the first tick (got %#04x)", opcodesOf(got))
	}
	if mv, err := DecodeMonsterMoved(first.Data); err != nil || mv.MonsterID != m.ID || mv.Mode != 1 || mv.Speed != 22 {
		t.Fatalf("the first push %+v (err %v), want monster %d's chase at mode 1, speed 22", mv, err, m.ID)
	}
	// 140 units at 22 u/s: about 64 ticks. No blow until the band.
	inReach := false
	for i := 0; i < 90 && !inReach; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
		cur, _ := z.monsters.Get(m.ID)
		inReach = int(math.Trunc(math.Hypot(cur.X-z.aria.x, cur.Z-z.aria.z))) <= 12
	}
	if !inReach {
		t.Fatal("the chase never brought the monster into its band in 9 s")
	}
	before, strike := z.aria.readUntil(t, OpMonsterAttacked, 3*time.Second)
	if strike == nil {
		t.Fatalf("no OpMonsterAttacked reached Aria within 3 s of the monster reaching its band (got %#04x)", opcodesOf(before))
	}
	for _, p := range before[:len(before)-1] {
		if p.Opcode != OpMonsterMoved {
			t.Errorf("Aria received %#04x during the chase, want only legs before the blow", p.Opcode)
		}
	}
	blow, err := DecodeMonsterAttacked(strike.Data)
	want := MonsterAttacked{MonsterID: m.ID, TargetCharacterID: z.ariaChar, Damage: 15, TargetHP: int32(character.StartingMaxHP) - 15}
	if err != nil || *blow != want {
		t.Errorf("the blow %+v (err %v), want %+v", blow, err, want)
	}
	if c, err := z.chars.GetByID(ctx, z.ariaChar); err != nil || c.HP != character.StartingMaxHP-15 {
		t.Errorf("Aria's HP = %d (err %v), want %d", c.HP, err, character.StartingMaxHP-15)
	}
	bramStrikes := strikes(t, z.bram.barrier(t))
	if len(bramStrikes) != 1 || *bramStrikes[0] != want {
		t.Errorf("Bram received %d OpMonsterAttacked %+v, want exactly the one blow %+v", len(bramStrikes), bramStrikes, want)
	}
	if n := len(strikes(t, z.cyra.barrier(t))); n != 0 {
		t.Errorf("Cyra, in donwhang, received %d OpMonsterAttacked, want 0", n)
	}
}

// ---- The player's dead state, the server half (round 549) ----

// THE RED at the wire (round 549), on the synchronous counter (-monster-battle
// off, -player-dead-state on): Aria's swing draws a killing counter, and her
// OpAttackResult and the zone's OpMonsterAttacked both carry PlayerDied with
// HP 0 -- no respawn in the same call. Dead, her next swing is refused with
// deadRefusal and her move reaches nobody. OpRevive (empty, round 548's
// request) answers an OpReviveResult with character.RespawnFraction of each
// maximum, followed by the stats push; alive again her move relays, a second
// OpRevive is "not dead", and a fresh monster's counter lands on her. Before
// this round the result and the push carried HP 80 (the respawn) and no
// swing was ever refused for being dead -- TestMonsterStrikePushCarriesTheFlags
// still pins the respawned HP with the flag off (the control).
func TestCounterKillLeavesThePlayerDeadUntilRevived(t *testing.T) {
	strikePushForTest(t, true)
	deadStateForTest(t, true)
	ctx := context.Background()
	tracker := mana.NewTracker()
	z := startStrikeZone(t, func(chars character.Store, hub *world.Hub, _ *combat.Hub) gateway.Handler {
		return ReviveHandler(chars, hub, RegenDeps{Mana: tracker})
	})
	k := z.monsters.SpawnSpecies("jangan", strikeMangyang, z.aria.x, 0, z.aria.z, 100000, 0, 100000, 0)

	res, ariaAfter := z.aria.attack(t, k.ID)
	if !res.PlayerDied || res.PlayerHP != 0 {
		t.Fatalf("the killing counter's result %+v; want PlayerDied with PlayerHP 0", res)
	}
	ariaStrikes := strikes(t, ariaAfter)
	if len(ariaStrikes) != 1 || !ariaStrikes[0].TargetDied || ariaStrikes[0].TargetHP != 0 {
		t.Errorf("Aria's own push %+v, want one blow with TargetDied and TargetHP 0", ariaStrikes)
	}
	bramStrikes := strikes(t, z.bram.barrier(t))
	if len(bramStrikes) != 1 || !bramStrikes[0].TargetDied || bramStrikes[0].TargetHP != 0 {
		t.Errorf("Bram's push %+v, want one blow with TargetDied and TargetHP 0", bramStrikes)
	}
	c, err := z.chars.GetByID(ctx, z.ariaChar)
	if err != nil {
		t.Fatal(err)
	}
	if c.HP != 0 {
		t.Errorf("Aria's stored HP after the kill = %d, want 0", c.HP)
	}
	if e, ok := z.hub.EntityByCharacterID(z.ariaChar); !ok || e.Life != world.LifeDead {
		t.Errorf("Aria's life state after the kill = %d (in world %v), want 2", e.Life, ok)
	}

	// Dead: a swing is refused before anything else is measured.
	z.aria.write(t, OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: k.ID}).Encode())
	p := z.aria.read(t)
	if p.Opcode != OpAttackResult {
		t.Fatalf("a dead swing was answered with %#04x, want OpAttackResult", p.Opcode)
	}
	if ar, err := DecodeAttackResult(p.Data); err != nil || ar.Error != deadRefusal {
		t.Errorf("a dead swing's result %+v (err %v), want the refusal %q", ar, err, deadRefusal)
	}
	// Dead: a move is neither stored nor relayed.
	z.aria.write(t, OpMove, (&MoveRequest{X: 50, Y: 0, Z: 50}).Encode())
	z.aria.barrier(t)
	for _, p := range z.bram.barrier(t) {
		if p.Opcode == OpEntityMoved {
			t.Errorf("Bram was relayed a dead character's move")
		}
	}
	if e, _ := z.hub.EntityByCharacterID(z.ariaChar); e.Pos.X == 50 {
		t.Errorf("a dead character's move was stored")
	}

	// The revive, on round 548's empty request.
	z.aria.write(t, OpRevive, nil)
	p = z.aria.read(t)
	if p.Opcode != OpReviveResult {
		t.Fatalf("OpRevive was answered with %#04x, want OpReviveResult", p.Opcode)
	}
	rr, err := DecodeReviveResult(p.Data)
	if err != nil || rr.Error != "" {
		t.Fatalf("the revive result %+v (err %v), want a success", rr, err)
	}
	reborn, _ := z.chars.GetByID(ctx, z.ariaChar)
	wantHP := reviveHPDelta(reborn.MaxHP()) // 1 + trunc(0.4 x max), the handler's sum from 0 (round 550)
	if int(rr.HP) != wantHP || reborn.HP != wantHP {
		t.Errorf("revived at HP %d (stored %d), want %d: 1 + trunc(0.4 x %d)", rr.HP, reborn.HP, wantHP, reborn.MaxHP())
	}
	if want := character.RespawnMP(reborn.MaxMP()); int(rr.MP) != want || tracker.Current(z.ariaChar, reborn.MaxMP()) != want {
		t.Errorf("revived at MP %d (tracker %d), want %d", rr.MP, tracker.Current(z.ariaChar, reborn.MaxMP()), want)
	}
	if p = z.aria.read(t); p.Opcode != OpCharacterStatsResult {
		t.Errorf("after the revive result Aria received %#04x, want the stats push", p.Opcode)
	}
	if e, ok := z.hub.EntityByCharacterID(z.ariaChar); !ok || e.Life != world.LifeAlive {
		t.Errorf("Aria's life state after the revive = %d, want 1", e.Life)
	}
	// Alive: the move relays, a second revive finds nobody dead, and a fresh
	// monster's counter lands.
	z.aria.write(t, OpMove, (&MoveRequest{X: 50, Y: 0, Z: 50}).Encode())
	z.aria.barrier(t)
	moved := false
	for _, p := range z.bram.barrier(t) {
		if p.Opcode == OpEntityMoved {
			moved = true
		}
	}
	if !moved {
		t.Errorf("Bram was not relayed the revived character's move")
	}
	z.aria.write(t, OpRevive, nil)
	if rr, err := DecodeReviveResult(z.aria.read(t).Data); err != nil || rr.Error != "not dead" {
		t.Errorf("a living character's OpRevive answered %+v (err %v), want \"not dead\"", rr, err)
	}
	z.aria.x, z.aria.z = 50, 50
	m := z.monsters.SpawnSpecies("jangan", strikeMangyang, z.aria.x, 0, z.aria.z, 1000, 0, 15, 0)
	if res2, _ := z.aria.attack(t, m.ID); res2.PlayerDamageTaken != 15 || res2.PlayerHP != int32(wantHP-15) {
		t.Errorf("the revived player's next fight %+v; want a 15-point counter from %d", res2, wantHP)
	}
}
