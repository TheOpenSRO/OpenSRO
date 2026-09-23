package session

import (
	"bufio"
	"context"
	"errors"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
	"github.com/OpenSRO/srrevamp/server/internal/skill"
)

// The first real Bicheon skill, pinned from the user's own skilldata export
// (skills.csv from Media.pk2, 2026-09-19): SKILL_CH_SWORD_SMASH_A_01 is skill
// id 3 (group 174), ReqCommon_Mastery1 257 (Bicheon), ReqCommon_MasteryLevel1
// 5, ReqLearn_SP 2 -- raw skilldata columns 34 / 36 / 46, CSV fields 22 / 23 /
// 19. No Bicheon skill has a lower requirement than this one except the
// basic swing (SKILL_CH_SWORD_BASE_01, requirement 0), so a character whose
// Bicheon is below 5 has nothing to learn there -- which is what a level-3
// character with Bicheon 3 saw, and asked about, on the public server.
const (
	smashA1ID           = 3
	smashA1Mastery      = 257
	smashA1MasteryLevel = 5
	smashA1SP           = 2
)

type smashA1Ref struct{}

func (smashA1Ref) GetSkill(_ context.Context, id int64) (*refdata.Skill, error) {
	if id == smashA1ID {
		return &refdata.Skill{
			ID: smashA1ID, GroupID: 174, BasicCode: "SKILL_CH_SWORD_SMASH_A_01", BasicLevel: 1,
			Mastery1: smashA1Mastery, MasteryLevel1: smashA1MasteryLevel, ReqLearnSP: smashA1SP,
		}, nil
	}
	return nil, errors.New("no such skill")
}

// TestLearnGateOnTheRealFirstBicheonSkill drives LearnSkillHandler with the
// real Power Strike row: refused below Bicheon 5 however many points are
// held, refused at Bicheon 5 with too few points, learned at Bicheon 5 for
// exactly its 2 SP.
func TestLearnGateOnTheRealFirstBicheonSkill(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	acct, err := accounts.Add("alice", "hunter2")
	if err != nil {
		t.Fatalf("accounts.Add: %v", err)
	}
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, acct.ID, "Aria")
	if err != nil {
		t.Fatalf("chars.Create: %v", err)
	}
	skills := skill.NewMemStore()

	handle := gateway.Chain(LoginHandler(accounts), LearnSkillHandler(chars, skills, smashA1Ref{}))
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()
	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)
	send := func(opcode uint16, data []byte) *proto.Packet {
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
	learn := func() *LearnSkillResult {
		t.Helper()
		resp := send(OpLearnSkill, (&LearnSkillRequest{CharacterName: "Aria", SkillID: smashA1ID}).Encode())
		lr, err := DecodeLearnSkillResult(resp.Data)
		if err != nil {
			t.Fatalf("DecodeLearnSkillResult: %v", err)
		}
		return lr
	}
	raise := func(to int) {
		t.Helper()
		for {
			lv, _ := skills.MasteryLevels(ctx, c.ID)
			if lv[smashA1Mastery] >= to {
				return
			}
			if _, err := skills.RaiseMastery(ctx, c.ID, smashA1Mastery, 0, seedMasteryCap); err != nil {
				t.Fatalf("RaiseMastery: %v", err)
			}
		}
	}

	resp := send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}

	// The user's situation: Bicheon 3, nine points. Nothing to learn -- the
	// mastery is the gate, not the points.
	raise(3)
	skills.AddSkillPoints(ctx, c.ID, 9)
	if lr := learn(); lr.OK || lr.Reason != "mastery level too low" {
		t.Fatalf("at Bicheon 3 with 9 SP: got %+v, want refused 'mastery level too low'", lr)
	}

	// Bicheon 5 with one point short of the row's 2 SP.
	raise(5)
	skills.AddSkillPoints(ctx, c.ID, -8) // 9 -> 1
	if lr := learn(); lr.OK || lr.Reason != "not enough skill points" {
		t.Fatalf("at Bicheon 5 with 1 SP: got %+v, want refused 'not enough skill points'", lr)
	}

	// Bicheon 5 with exactly the 2 SP the row asks: learned, points spent.
	skills.AddSkillPoints(ctx, c.ID, 1) // 1 -> 2
	if lr := learn(); !lr.OK {
		t.Fatalf("at Bicheon 5 with 2 SP: got %+v, want learned", lr)
	}
	if left, _ := skills.SkillPoints(ctx, c.ID); left != 0 {
		t.Fatalf("points after learning = %d, want 0 (the row costs %d)", left, smashA1SP)
	}
	if known, _ := skills.Knows(ctx, c.ID, smashA1ID); !known {
		t.Fatalf("skill %d not recorded as known after a successful learn", smashA1ID)
	}
}
