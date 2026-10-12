package session

// Round 785: every player attack row of the operator's own skills.csv cast
// through the real handler at a monster with neighbours (run with
// OPENSRO_SKILLS_CSV naming the round-785 export; skipped without it -- no
// game data is in the repository). It checks that no row panics or leaves
// its answer undecodable, that every accepted cast's action block names the
// primary first and carries the row's hit count, and it reports the
// refusals by reason.

import (
	"bufio"
	"context"
	"net"
	"os"
	"sort"
	"strings"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/mana"
	"github.com/OpenSRO/OpenSRO/server/internal/quest"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/skill"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

func TestR785EveryPlayerAttackRow(t *testing.T) {
	path := os.Getenv("OPENSRO_SKILLS_CSV")
	if path == "" {
		t.Skip("OPENSRO_SKILLS_CSV not set")
	}
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	rows, err := refdata.LoadSkillsCSV(f)
	f.Close()
	if err != nil {
		t.Fatal(err)
	}
	ref := refdata.NewMemStore()
	if err := ref.ImportSkills(context.Background(), rows); err != nil {
		t.Fatal(err)
	}
	var attack []refdata.Skill
	for _, r := range rows {
		if !strings.HasPrefix(r.BasicCode, "SKILL_CH_") && !strings.HasPrefix(r.BasicCode, "SKILL_EU_") {
			continue
		}
		if r.Mastery1 == 0 || r.ReqLearnSP == 0 || r.ActionKind == 3 || !r.TargetRequired || r.TargetLand ||
			r.TargetSelf || r.TargetAlly || r.TargetParty || r.NoCombatParam || r.ZeroDamage {
			continue
		}
		attack = append(attack, r)
	}
	sort.Slice(attack, func(i, j int) bool { return attack[i].ID < attack[j].ID })
	// The harness's own departures, so every row reaches its blow: no weapon
	// gate and no re-use timer (each row is cast once; a shared group's
	// timer would refuse its siblings). Race decides the character.
	for i := range attack {
		attack[i].ReqCastWeapon1, attack[i].ReqCastWeapon2, attack[i].ReqCastListCount = 255, 255, 0
		attack[i].ReuseDelayMs, attack[i].CooldownGroup = 0, 0
	}
	ref = refdata.NewMemStore()
	all := append([]refdata.Skill(nil), rows...)
	byID := map[int64]int{}
	for i, r := range all {
		byID[r.ID] = i
	}
	for _, r := range attack {
		all[byID[r.ID]] = r
	}
	if err := ref.ImportSkills(context.Background(), all); err != nil {
		t.Fatal(err)
	}
	refused := map[string]int{}
	accepted, multi, multiHit, knocked := 0, 0, 0, 0
	for _, eu := range []bool{false, true} {
		ctx := context.Background()
		accounts := account.NewMemStore()
		accounts.Add("alice", "hunter2")
		chars := character.NewMemStore()
		c, err := chars.Create(ctx, 1, "Aria")
		if err != nil {
			t.Fatal(err)
		}
		gender := character.GenderChinaMan
		if eu {
			gender = character.GenderEuropeMan
		}
		chars.SetGender(ctx, c.ID, gender)
		chars.SetLeveling(ctx, c.ID, 100, 0, 0, 500, 500)
		items := stubCombatItems{}
		inv := inventory.NewMemStore(items)
		eq := equipment.NewMemStore(inv)
		skills := skill.NewMemStore()
		var mine []refdata.Skill
		for _, r := range attack {
			if strings.HasPrefix(r.BasicCode, "SKILL_EU_") == eu {
				mine = append(mine, r)
				skills.Learn(ctx, c.ID, r.ID)
			}
		}
		hub := world.NewHub()
		monsters := combat.NewHub()
		mp := mana.NewTracker()
		handle := gateway.Chain(LoginHandler(accounts), WorldHandler(chars, eq, hub),
			UseSkillHandler(chars, eq, items, skills, hub, monsters, quest.NewMemStore(), inv, ref, nil, mp, nil))
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		addr := ln.Addr().String()
		ln.Close()
		srv := &gateway.Server{Addr: addr, Handle: handle, OnDisconnect: WorldDisconnectHandler(hub, nil)}
		sctx, cancel := context.WithCancel(context.Background())
		go srv.ListenAndServe(sctx)
		conn := dialTestServer(t, addr)
		w := &healWorld{aria: c.ID, mp: mp, skills: skills, conn: conn, r: bufio.NewReader(conn)}
		w.send(t, OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
		w.next(t, OpLoginResult)
		w.send(t, OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
		w.next(t, OpEnterWorldResult)
		me, _ := hub.EntityByCharacterID(c.ID)
		for _, r := range mine {
			me, _ = hub.EntityByCharacterID(c.ID) // a sprint or a knock may have moved things
			p := monsters.Spawn(me.Zone, "Dummy", me.Pos.X+2, me.Pos.Y, me.Pos.Z, 10000000, 0, 0, 0)
			n := monsters.Spawn(me.Zone, "Dummy", me.Pos.X+5, me.Pos.Y, me.Pos.Z+3, 10000000, 0, 0, 0)
			mp.Refill(c.ID, 1000000)
			w.send(t, OpUseSkill, (&UseSkillRequest{CharacterName: "Aria", SkillID: r.ID, TargetMonsterID: p.ID}).Encode())
			ar, err := DecodeAttackResult(w.next(t, OpAttackResult).Data)
			if err != nil {
				t.Fatalf("row %d %s: %v", r.ID, r.BasicCode, err)
			}
			pm, pok := monsters.Get(p.ID)
			monsters.Remove(p.ID)
			monsters.Remove(n.ID)
			if ar.Error == "target not found" && refused[ar.Error] == 0 {
				t.Logf("first 'target not found': row %d, primary %v %+v, previous accepted %d", r.ID, pok, pm, accepted)
			}
			if ar.Error != "" {
				if refused[ar.Error] < 3 {
					now, _ := hub.EntityByCharacterID(c.ID)
					t.Logf("row %d %s refused %q (me %+v %v, life %v)", r.ID, r.BasicCode, ar.Error, now.Pos, now.Zone, now.Life)
				}
				refused[ar.Error]++
				continue
			}
			accepted++
			a := ar.Action
			if a == nil || len(a.Targets) == 0 || a.Targets[0].UID != uint32(p.ID) || int(a.HitCount) != r.HitsFor() {
				t.Fatalf("row %d %s: action %+v", r.ID, r.BasicCode, a)
			}
			if len(a.Targets) > 1 {
				multi++
			}
			if a.HitCount > 1 {
				multiHit++
			}
			for _, h := range a.Targets[0].Hits {
				if k := h.Kind & 0x7f; k == HitKindKnockdown || k == HitKindKnockback {
					knocked++
					break
				}
			}
			nextChain(c.ID) // the chains' links are not this test's
		}
		conn.Close()
		cancel()
	}
	t.Logf("%d attack rows: %d accepted (%d struck more than one target, %d more than one hit, %d knocked), refused %v",
		len(attack), accepted, multi, multiHit, knocked, refused)
}
