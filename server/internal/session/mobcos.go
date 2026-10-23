package session

import (
	"context"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/ai"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/cos"
	"github.com/TheOpenSRO/OpenSRO/server/internal/jobs"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Monsters against a COS (round 804). READ in SR_GameServer.exe:
//
//   - AITactics_AcquireTarget (s:0x5478f0) scans with the kind pair its
//     tactics row's +0x90 flags pick: (selector 2, mask 1) the players
//     only; bit 0x4 (3, 5) and bit 0x80 (4, 5) the players and the COS (mask
//     bit 4, AITactics_ScanForTargets s:0x5405b0's object list), selector 3
//     keeping the traders' and hunters' side, 4 the thieves' (the NPC thieves'
//     rows 2001..2004 carry 542 = bit 0x4, the hunters' 2011..2014 666 =
//     bit 0x80); bit 0x100 (5, 0x11) is not used by them.
//   - CGObjMob::vslot_394 (s:0x529110) judges a COS by its owner's job
//     (jobs.MobMayTarget).
//   - A transport a monster kills drops its goods with no owner (COS slot
//     398, s:0x4d1fd0 -> s:0x4c3f60 with no killing player).
//
// OURS, disclosed: the COS a scan may take are the transports and the
// growth pets in the monster's zone that nobody rides (INFERRED: the object
// list's kinds are not read; an ability pet has no fight); a monster's blow
// on a COS rolls the monster's swing against the COS row's level, defence
// and block as a player's blow on a COS does (jobpvp.go), with no wall and
// no states; the zone hears it as an OpMonsterAttacked naming the COS uid.

// cosScanFlags is the scan's COS kinds for a tactics row: 0 none, else the
// owner side kept (jobs.StateTrader for the traders' and hunters', or
// jobs.StateThief).
func cosScanSide(t *combat.Tactics) byte {
	if t == nil {
		return 0
	}
	switch {
	case t.Flags&0x4 != 0:
		return jobs.StateTrader
	case t.Flags&0x80 != 0:
		return jobs.StateThief
	}
	return 0
}

// sideKeeps is selector 3 / 4: an owner of side's camp.
func sideKeeps(side, ownerJob byte) bool {
	switch side {
	case jobs.StateTrader:
		return ownerJob == jobs.StateTrader || ownerJob == jobs.StateHunter
	case jobs.StateThief:
		return ownerJob == jobs.StateThief
	}
	return false
}

// cosTargetEntity is a COS uid as the AI's target: its zone, position and
// life, the uid in CharacterID.
func cosTargetEntity(id int64) (world.Entity, bool) {
	if !isCOSUID(id) {
		return world.Entity{}, false
	}
	o := cosWorld.get(uint32(id))
	if o == nil {
		return world.Entity{}, false
	}
	cosWorld.mu.Lock()
	defer cosWorld.mu.Unlock()
	e := world.Entity{CharacterID: id, Zone: o.zone, Pos: o.at(time.Now()), Level: o.rec.Level, Life: world.LifeAlive}
	if o.dead || o.rec.HP <= 0 {
		e.Life = world.LifeDead
	}
	return e, true
}

// targetEntity is the brain's target as an entity: a character from the
// world hub, a COS from the COS world.
func (a *monsterAI) targetEntity(id int64) (world.Entity, bool) {
	if isCOSUID(id) {
		return cosTargetEntity(id)
	}
	if a.world == nil {
		return world.Entity{}, false
	}
	return a.world.EntityByCharacterID(id)
}

// cosCandidates adds the COS a scan of b's tactics may take (mask bit 4).
func (a *monsterAI) cosCandidates(ctx context.Context, b *brain, cands []ai.Candidate) []ai.Candidate {
	side := cosScanSide(b.m.Tactics)
	if side == 0 {
		return cands
	}
	type seen struct {
		uid   uint32
		owner int64
		x, z  float64
	}
	var list []seen
	now := time.Now()
	cosWorld.mu.Lock()
	for _, o := range cosWorld.byUID {
		if o.dead || o.zone != b.m.Zone || o.ridden || (o.kind != cos.KindTransport && o.kind != cos.KindGrowth) {
			continue
		}
		p := o.at(now)
		list = append(list, seen{o.uid, o.owner, p.X, p.Z})
	}
	cosWorld.mu.Unlock()
	for _, s := range list {
		job := jobStateNow(ctx, s.owner)
		if !sideKeeps(side, job) || !jobMobMayTarget(b.m.CodeName, int64(s.uid)) {
			continue
		}
		cands = append(cands, ai.Candidate{ID: int64(s.uid), X: s.x, Z: s.z})
	}
	return cands
}

// runCOSStrike is runStrike's blow on a COS.
func (a *monsterAI) runCOSStrike(id int64, job strikeJob) {
	o := cosWorld.get(uint32(job.target))
	if o == nil {
		return
	}
	cosWorld.mu.Lock()
	dead := o.dead || o.rec.HP <= 0
	row := o.row
	cosWorld.mu.Unlock()
	if dead {
		a.tracef("ai: monster %d swing at COS %d dropped: it is dead", id, job.target)
		return
	}
	swung := job.m
	if job.skill.ID != 0 {
		swung.AttackMin, swung.AttackMax = job.skill.AttMin, job.skill.AttMax
	}
	var out monsterStrikeOutcome
	if swung.AttackMax > 0 || swung.Attack > 0 {
		raw := job.m.Attack
		if swung.AttackMax > 0 {
			raw = monsterBlow(swung, row.Level, float64(combat.MonsterRate(row.Level)))
		}
		blow := resolveBlow(raw, row.Level, row.Defense(), combat.EvadedChance(job.m.Critical, monsterEvasion),
			row.Block(), job.m.Level, row.Level, job.m.ID, job.target)
		out.critical, out.blocked = blow.Critical, blow.Blocked
		if !blow.Blocked {
			out.damage = blow.Damage
			if out.damage < 1 {
				out.damage = 1
			}
		}
	}
	if out.damage > 0 {
		// No killing player: a transport's goods drop unowned (s:0x4c3f60).
		cosTakeDamageBy(o, out.damage, 0)
	}
	cosWorld.mu.Lock()
	out.hp = max(0, o.rec.HP)
	out.died = o.dead || o.rec.HP <= 0
	cosWorld.mu.Unlock()
	if out.died {
		a.mu.Lock()
		if _, live := a.brains[id]; live {
			a.kills[id] = struct{}{}
		}
		a.mu.Unlock()
	}
	a.tracef("ai: monster %d strike COS %d for %d (HP %d)%s", id, job.target, out.damage, out.hp,
		map[bool]string{true: " killed", false: ""}[out.died])
	msg := out.message(id, job.target)
	msg.SkillID = strikeSkillID(job.m, job.skill)
	a.emit(monsterPush{zone: job.m.Zone, cell: combat.CellOf(job.m.Zone, job.m.X, job.m.Z), id: id,
		packet: &proto.Packet{Opcode: OpMonsterAttacked, Data: msg.Encode()}}, nil)
}
