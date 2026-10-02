package session

import (
	"bufio"
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/leveldata"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
	"github.com/OpenSRO/srrevamp/server/internal/skill"
)

// Round 691: Europe's masteries and the race filter.
//
// The Europe fixture is pinned from the retail skilldata export (skills.csv,
// round 691's re-export on the render box): SKILL_EU_CLERIC_BATTLEA_CROSS_A_01
// is id 11557, group 764, ReqCommon_Mastery1 518 (Cleric) at level 4,
// ReqLearn_SP 2, ReqLearn_Race 1 -- the cheapest skill of its mastery, as
// SKILL_CH_SWORD_SMASH_A_01 (learngate_test.go) is of Bicheon. The China row
// gets its real ReqLearn_Race 0 here.
const (
	crossA1ID           = 11557
	crossA1Mastery      = 518
	crossA1MasteryLevel = 4
	crossA1SP           = 2
	// noMasteryRaceZeroID is a made-up row for the race clause alone: no
	// mastery requirement (so the held test passes) and ReqLearn_Race 0.
	noMasteryRaceZeroID = 900001
)

type raceRef struct{}

func (raceRef) GetSkill(_ context.Context, id int64) (*refdata.Skill, error) {
	switch id {
	case smashA1ID:
		return &refdata.Skill{
			ID: smashA1ID, GroupID: 174, BasicCode: "SKILL_CH_SWORD_SMASH_A_01", BasicLevel: 1,
			Mastery1: smashA1Mastery, MasteryLevel1: smashA1MasteryLevel, ReqLearnSP: smashA1SP, ReqLearnRace: 0,
		}, nil
	case crossA1ID:
		return &refdata.Skill{
			ID: crossA1ID, GroupID: 764, BasicCode: "SKILL_EU_CLERIC_BATTLEA_CROSS_A_01", BasicLevel: 1,
			Mastery1: crossA1Mastery, MasteryLevel1: crossA1MasteryLevel, ReqLearnSP: crossA1SP, ReqLearnRace: 1,
		}, nil
	case noMasteryRaceZeroID:
		return &refdata.Skill{ID: noMasteryRaceZeroID, GroupID: 9001, BasicCode: "TEST_RACE_ZERO_01", BasicLevel: 1, ReqLearnRace: 0}, nil
	}
	return nil, errors.New("no such skill")
}

// raceHarness is one logged-in connection over the skill handlers with a China
// character "Chen" and a Europe character "Erik", both of the given level, each
// holding 100,000 skill points.
type raceHarness struct {
	t      *testing.T
	ctx    context.Context
	chars  *character.MemStore
	skills *skill.MemStore
	china  int64
	europe int64
	send   func(opcode uint16, data []byte) *proto.Packet
}

func newRaceHarness(t *testing.T, level int) *raceHarness {
	t.Helper()
	ctx := context.Background()
	accounts := account.NewMemStore()
	acct, err := accounts.Add("alice", "hunter2")
	if err != nil {
		t.Fatalf("accounts.Add: %v", err)
	}
	h := &raceHarness{t: t, ctx: ctx, chars: character.NewMemStore(), skills: skill.NewMemStore()}
	mk := func(name, gender string) int64 {
		c, err := h.chars.Create(ctx, acct.ID, name)
		if err != nil {
			t.Fatalf("chars.Create(%s): %v", name, err)
		}
		if err := h.chars.SetGender(ctx, c.ID, gender); err != nil {
			t.Fatalf("SetGender: %v", err)
		}
		if err := h.chars.SetLeveling(ctx, c.ID, level, 0, 0, character.StartingStr, character.StartingInt); err != nil {
			t.Fatalf("SetLeveling: %v", err)
		}
		if _, err := h.skills.AddSkillPoints(ctx, c.ID, 100000); err != nil {
			t.Fatalf("AddSkillPoints: %v", err)
		}
		return c.ID
	}
	h.china = mk("Chen", character.GenderChinaMan)
	h.europe = mk("Erik", character.GenderEuropeMan)

	handle := gateway.Chain(LoginHandler(accounts), LearnSkillHandler(h.chars, h.skills, raceRef{}),
		RaiseMasteryHandler(h.chars, h.skills), SkillStateHandler(h.chars, h.skills))
	addr, cleanup := startTestServer(t, handle)
	t.Cleanup(cleanup)
	conn := dialTestServer(t, addr)
	t.Cleanup(func() { conn.Close() })
	r := bufio.NewReader(conn)
	h.send = func(opcode uint16, data []byte) *proto.Packet {
		t.Helper()
		if err := proto.Write(conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("Read: %v", err)
		}
		return resp
	}
	resp := h.send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}
	return h
}

func (h *raceHarness) learn(name string, id int64) *LearnSkillResult {
	h.t.Helper()
	resp := h.send(OpLearnSkill, (&LearnSkillRequest{CharacterName: name, SkillID: id}).Encode())
	lr, err := DecodeLearnSkillResult(resp.Data)
	if err != nil {
		h.t.Fatalf("DecodeLearnSkillResult: %v", err)
	}
	return lr
}

func (h *raceHarness) raise(name string, mastery int64) *RaiseMasteryResult {
	h.t.Helper()
	resp := h.send(OpRaiseMastery, (&RaiseMasteryRequest{CharacterName: name, MasteryID: mastery}).Encode())
	rr, err := DecodeRaiseMasteryResult(resp.Data)
	if err != nil {
		h.t.Fatalf("DecodeRaiseMasteryResult: %v", err)
	}
	return rr
}

// seed raises a mastery straight in the store, past the handler's checks.
func (h *raceHarness) seed(id, mastery int64, to int) {
	h.t.Helper()
	for {
		lv, _ := h.skills.MasteryLevels(h.ctx, id)
		if lv[mastery] >= to {
			return
		}
		if _, err := h.skills.RaiseMastery(h.ctx, id, mastery, 0, seedMasteryCap); err != nil {
			h.t.Fatalf("RaiseMastery: %v", err)
		}
	}
}

// TestLearnRaceFilter drives LearnSkillHandler across the race line: a Europe
// character cannot learn a China skill and a China character cannot learn a
// Europe one, whatever their points and mastery levels (FUN_0059e450's 0x3401,
// the mastery the character does not hold); a row with no mastery but a
// ReqLearn_Race of the other Country is refused by the race clause (0x3405);
// and each race learns its own.
func TestLearnRaceFilter(t *testing.T) {
	h := newRaceHarness(t, 20)
	// Seed both characters with BOTH races' masteries in the store (a row of
	// the other race cannot be raised through the handler any more; the seed
	// stands for anything a pre-691 server let through). The mastery level is
	// not what refuses: the held list is.
	for _, id := range []int64{h.china, h.europe} {
		h.seed(id, smashA1Mastery, 10)
		h.seed(id, crossA1Mastery, 10)
	}

	if lr := h.learn("Erik", smashA1ID); lr.OK || lr.Reason != "not your race's mastery" {
		t.Fatalf("Europe learns Power Strike (Bicheon): got %+v, want refused 'not your race's mastery'", lr)
	}
	if lr := h.learn("Chen", crossA1ID); lr.OK || lr.Reason != "not your race's mastery" {
		t.Fatalf("China learns Cross (Cleric): got %+v, want refused 'not your race's mastery'", lr)
	}
	if lr := h.learn("Erik", noMasteryRaceZeroID); lr.OK || lr.Reason != "not your race's skill" {
		t.Fatalf("Europe learns a ReqLearn_Race 0 row: got %+v, want refused 'not your race's skill'", lr)
	}
	if lr := h.learn("Chen", noMasteryRaceZeroID); !lr.OK {
		t.Fatalf("China learns a ReqLearn_Race 0 row: got %+v, want learned", lr)
	}
	// Each race's own: learned, and its ReqLearn_SP spent.
	before, _ := h.skills.SkillPoints(h.ctx, h.europe)
	if lr := h.learn("Erik", crossA1ID); !lr.OK {
		t.Fatalf("Europe learns Cross at Cleric 10: got %+v, want learned", lr)
	}
	if after, _ := h.skills.SkillPoints(h.ctx, h.europe); before-after != crossA1SP {
		t.Fatalf("Europe's points %d -> %d, want %d spent (the row's ReqLearn_SP)", before, after, crossA1SP)
	}
	if lr := h.learn("Chen", smashA1ID); !lr.OK {
		t.Fatalf("China learns Power Strike at Bicheon 10: got %+v, want learned", lr)
	}
	// The ordinary gate still applies to Europe: Cleric below 4 refuses.
	h2 := newRaceHarness(t, 20)
	h2.seed(h2.europe, crossA1Mastery, crossA1MasteryLevel-1)
	if lr := h2.learn("Erik", crossA1ID); lr.OK || lr.Reason != "mastery level too low" {
		t.Fatalf("Europe learns Cross at Cleric 3: got %+v, want 'mastery level too low'", lr)
	}
}

// TestRaiseMasteryRaceFilterAndEuropeCap drives RaiseMasteryHandler: a Europe
// character raises Warrior and cannot raise Bicheon, a China character the
// reverse (Mastery_LevelUp's 0x3801); Europe's total is min(240, 2 x level)
// (0x3805) while China's stays the flat 330 at the same level; and a raise
// spends leveldata's mastery cost.
func TestRaiseMasteryRaceFilterAndEuropeCap(t *testing.T) {
	prevTable := levelTable
	tbl, err := leveldata.ParseCSV(strings.NewReader("level,exp,mastery_sp\n1,67,3\n2,67,5\n3,67,7\n"))
	if err != nil {
		t.Fatalf("ParseCSV: %v", err)
	}
	SetLevelTable(tbl)
	t.Cleanup(func() { SetLevelTable(prevTable) })

	h := newRaceHarness(t, 10)
	if rr := h.raise("Erik", 257); rr.Error != "not your race's mastery" {
		t.Fatalf("Europe raises Bicheon: got %+v, want 'not your race's mastery'", rr)
	}
	if rr := h.raise("Chen", skill.MasteryWarrior); rr.Error != "not your race's mastery" {
		t.Fatalf("China raises Warrior: got %+v, want 'not your race's mastery'", rr)
	}
	// Every Europe mastery raises its first (free) point.
	for _, m := range skill.DefaultMasteries(1) {
		if rr := h.raise("Erik", m); rr.Error != "" || rr.NewLevel != 1 {
			t.Fatalf("Europe raises %d 0 -> 1: got %+v, want NewLevel 1", m, rr)
		}
	}
	// The SP: Warrior 1 -> 2 costs leveldata row 1's 3, 2 -> 3 row 2's 5.
	before, _ := h.skills.SkillPoints(h.ctx, h.europe)
	h.raise("Erik", skill.MasteryWarrior)
	h.raise("Erik", skill.MasteryWarrior)
	if after, _ := h.skills.SkillPoints(h.ctx, h.europe); before-after != 3+5 {
		t.Fatalf("Warrior 1 -> 3 spent %d SP, want 8 (leveldata rows 1 and 2)", before-after)
	}

	// The cap at level 10 is 2 x 10 = 20. The six masteries now sum 8 (3 + 5 x 1).
	h.seed(h.europe, skill.MasteryWizard, 10) // total 17
	h.seed(h.europe, skill.MasteryCleric, 4)  // total 20
	if rr := h.raise("Erik", skill.MasteryRogue); rr.Error != "mastery total at cap" {
		t.Fatalf("Europe level 10 at total 20 raises Rogue: got %+v, want 'mastery total at cap'", rr)
	}
	// China at the same level and a far larger total still raises: flat 330.
	h.seed(h.china, 257, 10)
	h.seed(h.china, 258, 10)
	h.seed(h.china, 259, 9)
	if rr := h.raise("Chen", 259); rr.Error != "" || rr.NewLevel != 10 {
		t.Fatalf("China level 10 at total 29 raises Pacheon: got %+v, want NewLevel 10", rr)
	}

	// The 240 ceiling binds at a level where 2 x level does not.
	hi := newRaceHarness(t, 130)
	hi.seed(hi.europe, skill.MasteryWarrior, 120)
	hi.seed(hi.europe, skill.MasteryRogue, 119)
	if rr := hi.raise("Erik", skill.MasteryRogue); rr.Error != "" || rr.NewLevel != 120 {
		t.Fatalf("Europe level 130 at total 239 raises Rogue: got %+v, want NewLevel 120", rr)
	}
	if rr := hi.raise("Erik", skill.MasteryWizard); rr.Error != "mastery total at cap" {
		t.Fatalf("Europe level 130 at total 240 raises Wizard: got %+v, want 'mastery total at cap' (240.0)", rr)
	}
	// A stored row of the other race is not in the engine's map, so it is not
	// in the total either: seeding Bicheon 50 on the Europe character changes
	// nothing above, and on a fresh level-10 Europe character it does not
	// count against 2 x level.
	lo := newRaceHarness(t, 10)
	lo.seed(lo.europe, 257, 50)
	if rr := lo.raise("Erik", skill.MasteryBard); rr.Error != "" || rr.NewLevel != 1 {
		t.Fatalf("Europe level 10 with a stored Bicheon 50 raises Bard: got %+v, want NewLevel 1", rr)
	}
}

// TestSkillStateListsTheRaceMasteries: OpSkillState carries every mastery the
// character's race holds, a level-0 one included, and nothing of the other
// race -- the list the client's skill window lays out (FUN_006aa3e0).
func TestSkillStateListsTheRaceMasteries(t *testing.T) {
	h := newRaceHarness(t, 10)
	h.seed(h.europe, skill.MasteryBard, 3)
	h.seed(h.europe, 257, 7) // another race's stored row: not sent
	state := func(name string) *SkillStateResult {
		resp := h.send(OpSkillState, (&SkillStateRequest{CharacterName: name}).Encode())
		r, err := DecodeSkillStateResult(resp.Data)
		if err != nil || r.Error != "" {
			t.Fatalf("SkillState(%s): err=%v result=%+v", name, err, r)
		}
		return r
	}
	eu := state("Erik")
	want := map[int64]int32{513: 0, 514: 0, 515: 0, 516: 0, 517: 3, 518: 0}
	if len(eu.Masteries) != len(want) {
		t.Fatalf("Europe masteries %+v, want the six of 513-518", eu.Masteries)
	}
	for _, m := range eu.Masteries {
		if lvl, ok := want[m.MasteryID]; !ok || lvl != m.Level {
			t.Fatalf("Europe masteries %+v, want %v", eu.Masteries, want)
		}
	}
	ch := state("Chen")
	if len(ch.Masteries) != 7 || ch.Masteries[0].MasteryID != 257 || ch.Masteries[6].MasteryID != 276 {
		t.Fatalf("China masteries %+v, want the seven of 257-259, 273-276", ch.Masteries)
	}
}
