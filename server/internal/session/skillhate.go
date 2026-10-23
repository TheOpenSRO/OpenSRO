package session

// Hate (round 785): what a skill's blow books on the monster's threat table
// (READ ~0x590450..0x5904d5; docs/protocol/skill_attack.md "Hate"): per hit
// hate += damage; a row with 'tant' makes it round(hate x (1 + tant[1]/100))
// + tant[0], else 'tnt2' the same; then x (1 + the attacker's p187/100).
// It is delivered to the AI as OnAttacked {source, damage, hate,
// hatePercent} and credited by ai.ThreatTable.Credit (AITactics_
// CreditAttacker 0x5473c0, round 259).
//
// OpenSRO's monster AI faces its first attacker and reads no threat table
// (monsterai.go, the AI lane): the table is kept here, per monster, for the
// AI's retarget rule to read (OPEN: wiring ai.ThreatTable.Resolve into the
// BATTLE tick).

import (
	"math"
	"sync"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/ai"
	"github.com/TheOpenSRO/OpenSRO/server/internal/buff"
)

var threats = struct {
	sync.Mutex
	m map[int64]*ai.ThreatTable
}{m: map[int64]*ai.ThreatTable{}}

// skillHate is one target's hate for the cast's hits (READ).
func skillHate(c *castContext, damage int) int {
	hate := float64(damage)
	if v, ok := c.rowValue("tant", 0); ok {
		v1, _ := c.rowValue("tant", 1)
		hate = math.Round(hate*(1+float64(v1)/100)) + float64(v)
	} else if v, ok := c.rowValue("tnt2", 0); ok {
		v1, _ := c.rowValue("tnt2", 1)
		hate = math.Round(hate*(1+float64(v1)/100)) + float64(v)
	}
	if t, ok := buffTotal(c.casterID, buff.ParamThreat); ok {
		hate = math.Round(hate * (1 + t.Apply(0)/100))
	}
	return int(hate)
}

// addSkillHate credits every surviving target with the cast's hate.
func addSkillHate(c *castContext, outcomes []targetOutcome) {
	now := time.Now().UnixMilli()
	threats.Lock()
	defer threats.Unlock()
	for _, o := range outcomes {
		if !o.ok || o.died {
			continue
		}
		// A monster that fell meanwhile (another's blow) is forgotten, or
		// about to be, by forgetThreat, which takes this lock: no entry is
		// made for it again (round 785 review).
		if c.d.monsters != nil {
			if m, alive := c.d.monsters.Get(o.before.ID); !alive || m.HP <= 0 {
				continue
			}
		}
		t := threats.m[o.before.ID]
		if t == nil {
			t = &ai.ThreatTable{}
			threats.m[o.before.ID] = t
		}
		t.Credit(c.casterID, o.total, skillHate(c, o.total), 0, now)
	}
}

func forgetThreat(id int64) {
	threats.Lock()
	delete(threats.m, id)
	threats.Unlock()
}
