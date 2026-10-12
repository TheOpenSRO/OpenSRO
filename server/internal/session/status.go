package session

// Monsters give and receive status effects (round 659).
//
// internal/statuseffect holds the rules, each READ out of SR_GameServer.exe
// and cited there: how a skill's status run lands (statuseffect.Resolve), one
// record per slot (Holder.Put), the pass that expires and ticks them
// (Holder.Step), and what a state stops (CanMove, CanAct, SpeedPercent). This
// file wires them to OpenSRO's objects:
//
//   - a player's skill that lands on a monster applies its runs to it
//     (applyToMonster: skill.go, after the blow, and for a zero-damage cast);
//   - a monster's attack skill applies its runs to the character it lands on
//     (applyToCharacter: monsterStrike), never to one who is dead;
//   - RunStatusEffects steps every holder: a state's damage tick is dealt, a
//     killing tick on a monster pays its source exactly as a killing blow does
//     (grantKill + announceKill, combat.go), and a killing tick on a character
//     is the death a blow would be (finishKill, monsterstrike.go);
//   - a stunned, frozen or sleeping monster neither moves nor strikes, a
//     rooted one does not move, and frostbite and slow slow its next leg
//     (monsterai.go's two calls, heldByStatus and statusSpeed);
//   - every change of an object's mask goes to its zone as OpObjectStatus.
//
// Labels as everywhere: READ, MEASURED, INFERRED, OURS, OPEN.

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/ai"
	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/statuseffect"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// OpObjectStatus is an object's abnormal-state mask, server -> every session
// in the object's zone. The number is retail's 0x3057, and the payload is
// that message's flag-4 block (sro_client.exe's handler 0x8a9e30:
// `if (flags & 4) { Read(mask, 4); 0x9cd5e0(mask); 0x9d2220(mask, stream) }`,
// the second reading one level byte for each set bit in
// statuseffect.LevelBits, low bit first). READ, the block. OURS, the head:
// OpenSRO names an object by (owner kind, int64 id) where retail sends a u32
// unique id, and sends only flag 4 -- retail's flag 1 (HP) and 2 (MP) are not
// used, since OpMonsterDamaged and OpCharacterStatsResult already carry them.
//
//	u8  owner kind (OwnerCharacter 0, OwnerMonster 1, as OpBuffStart's)
//	i64 id
//	u16 cause  (retail's second field; 0)
//	u8  flags  (4)
//	u32 mask   (flags & 4)
//	u8  level  x one per set bit of mask & 0x17fefc0, low to high
const OpObjectStatus uint16 = 0x3057

// ObjectStatusFlagMask is 0x3057's abnormal-state flag. READ.
const ObjectStatusFlagMask = 0x4

// ObjectStatus is OpObjectStatus's payload.
type ObjectStatus struct {
	OwnerKind uint8
	OwnerID   int64
	Mask      uint32
	Levels    []byte
}

// Encode writes the payload (little-endian, as every OpenSRO message).
func (m *ObjectStatus) Encode() []byte {
	out := []byte{m.OwnerKind}
	out = binary.LittleEndian.AppendUint64(out, uint64(m.OwnerID))
	out = binary.LittleEndian.AppendUint16(out, 0)
	out = append(out, ObjectStatusFlagMask)
	out = binary.LittleEndian.AppendUint32(out, m.Mask)
	return append(out, m.Levels...)
}

// DecodeObjectStatus reads a payload, taking one level byte per set bit the
// client reads one for.
func DecodeObjectStatus(data []byte) (*ObjectStatus, error) {
	if len(data) < 12 {
		return nil, errors.New("object status: short")
	}
	m := &ObjectStatus{OwnerKind: data[0], OwnerID: int64(binary.LittleEndian.Uint64(data[1:9]))}
	flags := data[11]
	rest := data[12:]
	if flags&ObjectStatusFlagMask == 0 {
		return m, nil
	}
	if len(rest) < 4 {
		return nil, errors.New("object status: short mask")
	}
	m.Mask = binary.LittleEndian.Uint32(rest)
	rest = rest[4:]
	for bit := 0; bit < 32; bit++ {
		b := uint32(1) << uint(bit)
		if m.Mask&b == 0 || statuseffect.LevelBits&b == 0 {
			continue
		}
		if len(rest) == 0 {
			return nil, errors.New("object status: short levels")
		}
		m.Levels = append(m.Levels, rest[0])
		rest = rest[1:]
	}
	return m, nil
}

// StatusTick is how often RunStatusEffects steps the holders. OURS: the
// engine's pass rate (AbnormalState_UpdateOwnerClear's caller) is not read;
// every state keeps its own millisecond clock, so this only bounds how late a
// tick or an expiry lands.
const StatusTick = 100 * time.Millisecond

// statusRuntime is every object's states.
type statusRuntime struct {
	mu   sync.Mutex
	mobs map[int64]*statuseffect.Holder
	pcs  map[int64]*statuseffect.Holder
	// cdeps are what a kill by a tick pays through (grantKill, announceKill),
	// rebound by every player cast that lands a state; sdeps what a
	// character's death by a tick goes through (finishKill), rebound by every
	// monster blow that does. Each call passes the process's one set of
	// stores, so the latest is the same as the first. mons is the monster
	// hub a tick's caster is looked up in (RunStatusEffects, or the latest
	// cast's).
	cdeps combatDeps
	sdeps strikeDeps
	mons  *combat.Hub
	// legPct is the speed percent each monster's current leg was started at
	// (statusSpeed), for the republish when its states change (heldByStatus).
	legPct map[int64]int
	// stats are the stores the stats push reads (RunStatusEffects' deps,
	// regen.go's shape), so a bar a tick moved keeps its SP and MP lines.
	stats  RegenDeps
	epoch  time.Time
	logger *slog.Logger
}

func newStatusRuntime() *statusRuntime {
	return &statusRuntime{mobs: map[int64]*statuseffect.Holder{}, pcs: map[int64]*statuseffect.Holder{}, legPct: map[int64]int{}, epoch: time.Now()}
}

// statusFX is the process's runtime, package-level like buffBooks and
// chanceMemory: the states belong to the objects, not to one request.
var statusFX = newStatusRuntime()

// ms is t on the runtime's millisecond clock (GetTickCount's shape: a uint32
// that the engine's comparisons subtract, so a wrap is harmless).
func (s *statusRuntime) ms(t time.Time) uint32 {
	return uint32(t.Sub(s.epoch) / time.Millisecond)
}

// statusRoller is the chance-memory dice for one CASTER: the same
// accumulators and generator as a blow's critical and block, under a kind of
// their own per state (combat.ChanceStatus). READ (round 659's review): in
// Combat_ApplyStatusEffects the map is `[esi+0xa30]` with ESI the SOURCE --
// `[esi+8]` is what the block writes to record+0x4c, the id the appliers
// resolve as the caster, and the caller sets ESI from `[esp+0x124]` at
// 0x58f412, the object whose +0xa30 the critical roll uses at 0x58ed76 --
// and the key is `kind << 24` with no id bits. So a caster keeps one streak
// per state across all its targets.
func statusRoller(casterID int64) statuseffect.Roller {
	return func(chance, kind int) bool {
		damageRollMu.Lock()
		defer damageRollMu.Unlock()
		return combat.RollChanceTracked(chance, damageRollNG, chanceMemory, casterID, combat.ChanceStatus(kind))
	}
}

// applyToMonster lands castRow's status runs on monsterID, cast by
// characterID, and tells the zone when the mask changed.
// applyToMonster lands castRow's status runs on monsterID, cast by
// characterID, and tells the zone when the mask changed. It returns the bits
// of the states that landed (round 785: the hit record's statusBits,
// Combat_ApplyStatusEffects' return OR'd into hit+8, READ 0x58f72d).
func (s *statusRuntime) applyToMonster(d combatDeps, characterID int64, castRow *refdata.Skill, monsterID int64, now time.Time) uint32 {
	if castRow == nil || castRow.StatusParams == "" || d.monsters == nil {
		return 0
	}
	runs := statuseffect.ParseRuns(castRow.StatusParams)
	if len(runs) == 0 {
		return 0
	}
	m, ok := d.monsters.Get(monsterID)
	if !ok || m.HP <= 0 {
		return 0
	}
	// Only in the caster's own zone (round 659's review, H2): the cast paths
	// test reach and zone before here; this is the last guard.
	if d.hub != nil {
		if e, in := d.hub.EntityByCharacterID(characterID); !in || e.Zone != m.Zone {
			return 0
		}
	}
	// A monster resists nothing: characterdata cols 61-66 read 0 on every
	// row (MEASURED), so the resist arrays stay zero.
	recs := statuseffect.ResolveAll(runs, statuseffect.Target{Level: m.Level}, s.ms(now), statusRoller(characterID))
	if len(recs) == 0 {
		return 0
	}
	s.mu.Lock()
	s.cdeps, s.mons = d, d.monsters
	h := s.mobs[monsterID]
	if h == nil {
		h = &statuseffect.Holder{}
		s.mobs[monsterID] = h
	}
	before := h.Mask()
	var applied uint32
	for _, r := range recs {
		r.SourceID = characterID
		h.Put(r)
		applied |= statuseffect.MaskForSlot(r.Slot)
	}
	msg := &ObjectStatus{OwnerKind: OwnerMonster, OwnerID: monsterID, Mask: h.Mask(), Levels: h.Levels()}
	stops := !h.CanMove() || !h.CanAct()
	s.mu.Unlock()
	s.tracef("status: monster %d took %v from character %d (mask %#x -> %#x)", monsterID, codesOf(recs), characterID, before, msg.Mask)
	// The applier stops the move at once (vslot 0x570, READ). The stop is the
	// AI tick's (heldByStatus): it ends the leg AND puts the stop on the wire.
	// Ending it here instead (round 659, before its review) left the next
	// tick to find the monster already standing, so no stop was ever sent
	// and the clients kept drawing the leg (review H1). With no AI runtime
	// (-monster-ai off) there is no tick to do it, and no push to send: the
	// hub's leg is ended here (the re-review's L3).
	if stops && monsterAIRuntime.Load() == nil {
		d.monsters.StopMotion(monsterID)
	}
	pushMonsterStatus(d.hub, d.monsters, m, msg)
	return applied
}

// statusCastAtMonster reports whether a cast lands states on a monster
// target: a row carrying status runs that is no buff, ground cast, self cast
// or friendly cast.
func statusCastAtMonster(castRow *refdata.Skill, isBuff, isGround, selfTarget, friendly bool) bool {
	return castRow != nil && castRow.StatusParams != "" && !isBuff && !isGround && !selfTarget && !friendly
}

// statusCastRefusal is the target test for a cast that resolves no blow but
// lands states on a monster (round 659's review, H2): the monster must be
// alive in the caster's own zone ("target not found", performAttack's words
// for either) and within the skill's reach (skillInReach, the damaging
// cast's own test; "too far away").
func statusCastRefusal(ctx context.Context, sess *gateway.Session, eq equipment.Store, items combat.ItemLookup, hub *world.Hub, monsters *combat.Hub, characterID, target int64, skillRange int) string {
	if hub == nil || monsters == nil {
		return ""
	}
	m, ok := monsters.Get(target)
	caster, in := hub.EntityBySession(sess.ID())
	if !ok || m.HP <= 0 || !in || caster.Zone != m.Zone {
		return "target not found"
	}
	if !skillInReach(ctx, sess, eq, items, hub, monsters, characterID, target, skillRange) {
		return "too far away"
	}
	return ""
}

// pushMonsterStatus sends a monster's mask to the players whose window holds
// it (monsterWatchers, round 656's area of interest), each under its monster
// wire lock (sendMonsterPush) -- a monster's state goes where its damage
// goes, not to the whole zone.
func pushMonsterStatus(hub *world.Hub, monsters *combat.Hub, m combat.Monster, msg *ObjectStatus) {
	p := &proto.Packet{Opcode: OpObjectStatus, Data: msg.Encode()}
	for _, e := range monsterWatchers(hub, monsters, m) {
		if e.Session != nil {
			sendMonsterPush(e.Session, p)
		}
	}
}

// applyToCharacter lands a monster skill's status runs on characterID. Never
// on a dead character -- OURS: what the prologue of Combat_ApplyStatusEffects
// tests first is not read to be the life state (0x5906c0 `cmp [edi+5],2` is
// the HIT RECORD's blocked flag -- `[ebp+5] = 2` after the block roll at
// 0x58f0ef -- so a blocked blow applies nothing, which monsterStrike keeps).
func (s *statusRuntime) applyToCharacter(ctx context.Context, d strikeDeps, monster combat.Monster, skill combat.MonsterSkill, characterID int64) {
	if skill.Status == "" || d.chars == nil {
		return
	}
	runs := statuseffect.ParseRuns(skill.Status)
	if len(runs) == 0 || deadCharacter(d.hub, characterID) {
		return
	}
	c, err := d.chars.GetByID(ctx, characterID)
	if err != nil || c == nil || c.HP <= 0 {
		return
	}
	// OPEN: a character's resist params (27-32, 145-150) are not published
	// by OpenSRO, so every character resists nothing for now.
	now := time.Now()
	recs := statuseffect.ResolveAll(runs, statuseffect.Target{Level: c.Level}, s.ms(now), statusRoller(monster.ID))
	if len(recs) == 0 {
		return
	}
	s.mu.Lock()
	s.sdeps = d
	h := s.pcs[characterID]
	if h == nil {
		h = &statuseffect.Holder{}
		s.pcs[characterID] = h
	}
	for _, r := range recs {
		r.SourceID, r.SourceIsMonster = monster.ID, true
		h.Put(r)
	}
	msg := &ObjectStatus{OwnerKind: OwnerCharacter, OwnerID: characterID, Mask: h.Mask(), Levels: h.Levels()}
	stopped := !h.CanMove()
	s.mu.Unlock()
	s.tracef("status: character %d took %v from monster %d (mask %#x)", characterID, codesOf(recs), monster.ID, msg.Mask)
	if e, ok := entityOf(d.hub, characterID); ok {
		broadcastStatus(d.hub, e.Zone, msg)
	}
	// A state that stops a move ends the leg where the server has it (round
	// 749's review, F4; READ vslot 0x570 -> the slot-300 stop's 0xB023).
	if stopped && d.hub != nil {
		haltForState(d.hub, characterID)
	}
}

// characterCanMove reports whether characterID's states let it walk (round
// 749's review, F4: Holder.CanMove, the 0x7021 handler's 0xc1 | 0x4000 gate).
func (s *statusRuntime) characterCanMove(characterID int64) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	h := s.pcs[characterID]
	return h == nil || h.CanMove()
}

// monsterMayAct reports whether monsterID's states let it strike (the
// synchronous counter in performAttack).
func monsterMayAct(id int64) bool {
	_, act, _ := statusFX.monsterState(id)
	return act
}

// monsterState reports what monsterID's states allow: moving, acting, and the
// speed percent of its next leg.
func (s *statusRuntime) monsterState(id int64) (move, act bool, speed int) {
	// Round 785 (skillknock.go): a knocked-down or knocked-back monster is
	// held for the motion state's time.
	if _, knocked := knockOf(id, time.Now()); knocked {
		return false, false, 100
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	h := s.mobs[id]
	if h == nil {
		return true, true, 100
	}
	return h.CanMove(), h.CanActAt(s.ms(time.Now())), h.SpeedPercent()
}

// monsterMask is monsterID's abnormal-state mask (round 785: 'atca' tests
// it, target+0xd34, READ).
func (s *statusRuntime) monsterMask(id int64) uint32 {
	s.mu.Lock()
	defer s.mu.Unlock()
	if h := s.mobs[id]; h != nil {
		return h.Mask()
	}
	return 0
}

// addHeld adds to insistent every monster with a brain whose states stop it
// from moving or acting: under -monster-sleep (round 656) such a monster is
// kept awake, as one in BATTLE or HOMING is, so its stop and its release are
// the tick's and not frozen part-way. hasBrain answers for a brain awake or
// filed asleep (round 666: a sleeping monster's brain is dropped and its
// memory filed, and a hold still wakes it). The monster AI calls it under its
// lock.
func (s *statusRuntime) addHeld(insistent map[int64]struct{}, hasBrain func(id int64) bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	nowMs := s.ms(time.Now())
	for id, h := range s.mobs {
		if hasBrain(id) && (!h.CanMove() || !h.CanActAt(nowMs)) {
			insistent[id] = struct{}{}
		}
	}
	knocks.Lock()
	for id := range knocks.m {
		if hasBrain(id) {
			insistent[id] = struct{}{}
		}
	}
	knocks.Unlock()
}

// monsterDefenceCut is the flat defence bleeding takes off monsterID.
func (s *statusRuntime) monsterDefenceCut(id int64) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	if h := s.mobs[id]; h != nil {
		return h.DefenceCut()
	}
	return 0
}

// forgetMonster ends a monster's states: its death ends them (the object is
// gone; a respawn is a new monster with a new id -- cmd/server
// maintainMonster), so nothing is sent.
func (s *statusRuntime) forgetMonster(id int64) {
	s.mu.Lock()
	delete(s.mobs, id)
	delete(s.legPct, id)
	s.mu.Unlock()
	// Round 785: its knock, its debuffs and their rows go with it.
	forgetKnock(id)
	forgetMonsterBuffs(id)
}

// monsterTick is one damage tick on a monster, computed under the runtime's
// lock and dealt after it.
type monsterTick struct {
	zone string
	id   int64
	tick statuseffect.Tick
}

// characterTick is one damage tick on a character.
type characterTick struct {
	id   int64
	tick statuseffect.Tick
}

// statusPush is a mask to announce.
type statusPush struct {
	monster bool
	zone    string
	msg     *ObjectStatus
}

// casterLookup answers the damage appliers' question about a record's caster
// (statuseffect.SourceRule): a character in the world is alive unless her
// life state is DEAD; a monster is alive while the hub holds it -- OpenSRO
// removes a monster at its death, where the engine keeps the object a while
// in state 2, so a dead monster reads as gone (INFERRED equivalent: either
// way a poison it left names nobody).
func casterLookup(hub *world.Hub, mons *combat.Hub) statuseffect.CasterLookup {
	return func(id int64, isMonster bool) statuseffect.CasterState {
		if isMonster {
			if _, ok := monsterOf(mons, id); ok {
				return statuseffect.CasterAlive
			}
			return statuseffect.CasterGone
		}
		e, ok := entityOf(hub, id)
		switch {
		case !ok:
			return statuseffect.CasterGone
		case e.Life == world.LifeDead:
			return statuseffect.CasterDead
		}
		return statuseffect.CasterAlive
	}
}

// pcNow is what the pass needs of an afflicted character, read from the
// stores BEFORE the runtime's lock is taken (round 659's review, L2: a slow
// store read under it stalled every cast and the AI tick).
type pcNow struct {
	e     world.Entity
	in    bool
	alive bool
	hp    int
}

// step is one pass over every holder at now. Under the runtime's lock it only
// expires and ticks the records (Holder.Step) and notes what to deal and what
// to announce; the store reads come before it and the damage, the kills and
// the sends after it, outside the lock -- the monster AI's tick reads the
// runtime under its own lock (heldByStatus), so this pass never holds ours
// while it takes another's or waits on a store.
func (s *statusRuntime) step(ctx context.Context, now time.Time) {
	nowMs := s.ms(now)
	var pushes []statusPush
	var mticks []monsterTick
	var cticks []characterTick

	s.mu.Lock()
	cd, sd, st, mons := s.cdeps, s.sdeps, s.stats, s.mons
	ids := make([]int64, 0, len(s.pcs))
	for id := range s.pcs {
		ids = append(ids, id)
	}
	s.mu.Unlock()
	if mons == nil {
		mons = cd.monsters
	}
	hub := cd.hub
	if hub == nil {
		hub = sd.hub
	}
	pcs := make(map[int64]pcNow, len(ids))
	for _, id := range ids {
		var p pcNow
		p.e, p.in = entityOf(sd.hub, id)
		if sd.chars != nil && p.in && p.e.Life != world.LifeDead {
			if c, err := sd.chars.GetByID(ctx, id); err == nil && c != nil && c.HP > 0 {
				p.hp, p.alive = c.HP, true
			}
		}
		pcs[id] = p
	}
	caster := casterLookup(hub, mons)

	s.mu.Lock()
	for id := range s.legPct {
		if _, ok := monsterOf(mons, id); !ok {
			delete(s.legPct, id)
		}
	}
	for id, h := range s.mobs {
		m, ok := monsterOf(mons, id)
		if !ok || m.HP <= 0 {
			delete(s.mobs, id)
			continue
		}
		ticks, changed := h.Step(nowMs, m.HP, caster)
		for _, t := range ticks {
			mticks = append(mticks, monsterTick{zone: m.Zone, id: id, tick: t})
		}
		if changed {
			pushes = append(pushes, statusPush{monster: true, zone: m.Zone, msg: &ObjectStatus{OwnerKind: OwnerMonster, OwnerID: id, Mask: h.Mask(), Levels: h.Levels()}})
		}
		if h.Idle(nowMs) {
			delete(s.mobs, id)
		}
	}
	for id, h := range s.pcs {
		p, seen := pcs[id]
		if !seen {
			continue // afflicted after the reads: the next pass
		}
		if !p.alive {
			// Dead, or gone from the world: the states end (OURS for the
			// logout; a death clears them as a monster's does).
			if h.EndAll() && p.in {
				pushes = append(pushes, statusPush{zone: p.e.Zone, msg: &ObjectStatus{OwnerKind: OwnerCharacter, OwnerID: id}})
			}
			delete(s.pcs, id)
			continue
		}
		ticks, changed := h.Step(nowMs, p.hp, caster)
		for _, t := range ticks {
			cticks = append(cticks, characterTick{id: id, tick: t})
		}
		if changed {
			pushes = append(pushes, statusPush{zone: p.e.Zone, msg: &ObjectStatus{OwnerKind: OwnerCharacter, OwnerID: id, Mask: h.Mask(), Levels: h.Levels()}})
		}
		if h.Idle(nowMs) {
			delete(s.pcs, id)
		}
	}
	s.mu.Unlock()

	for _, p := range pushes {
		if p.monster {
			if m, ok := monsterOf(mons, p.msg.OwnerID); ok {
				pushMonsterStatus(hub, mons, m, p.msg)
			}
			continue
		}
		broadcastStatus(hub, p.zone, p.msg)
	}
	dead := map[int64]bool{}
	for _, mt := range mticks {
		if dead[mt.id] {
			continue
		}
		if err := s.dealMonsterTick(ctx, cd, mt); err != nil {
			if s.logger != nil {
				s.logger.Warn("status: a monster's damage tick", "monster", mt.id, "err", err)
			}
		}
		if _, alive := monsterOf(mons, mt.id); !alive {
			dead[mt.id] = true
		}
	}
	gone := map[int64]bool{}
	for _, ct := range cticks {
		if gone[ct.id] {
			continue
		}
		if died := s.dealCharacterTick(ctx, sd, st, ct); died {
			gone[ct.id] = true
		}
	}
}

// dealMonsterTick deals one tick through damageMonsterWatched -- the area of
// interest's damage path (round 656), which tells the players whose window
// held the monster before the tick and after it -- and settles a kill.
//
// Whom the applier names is READ (statuseffect.SourceRule): a living caster
// on every tick, poison's included; a dead caster only on a fatal burn or
// bleeding tick. What the engine does with that name is INFERRED: the
// appliers hand the damage to vslot 0x4fc, CGObjChar::Char_ForwardToAttached
// Object (0x4a7500), which forwards it to an object that is not read -- so
// that a named tick is booked on the monster's damage list (round 657; a
// DoT's damage then counts toward the unique notice's killer) and is the
// monster's struck event, as a blow is (a DoT-only debuff draws the monster
// onto its caster), are OpenSRO's reading of it, not the engine's text. Whether
// the tick is fatal is decided against the HP the monster has NOW (review L1),
// and a kill is credited from the damage call's own died result.
func (s *statusRuntime) dealMonsterTick(ctx context.Context, d combatDeps, mt monsterTick) error {
	m, ok := monsterOf(d.monsters, mt.id)
	if !ok {
		return nil
	}
	dmg := mt.tick.Damage
	if mt.tick.NeverKills {
		if dmg = min(dmg, m.HP-1); dmg <= 0 {
			return nil
		}
	}
	var attacker int64
	if !mt.tick.SourceIsMonster && mt.tick.Credited(dmg >= m.HP) {
		attacker = mt.tick.SourceID
	}
	updated, died, ok, watchers, hits := damageMonsterWatched(d.hub, d.monsters, mt.id, attacker, dmg)
	if !ok {
		return nil
	}
	s.tracef("status: monster %d %s tick %d (HP %d, booked to %d)", mt.id, mt.tick.Code, dmg, updated.HP, attacker)
	if !died {
		if attacker != 0 {
			noteStruck(d.monsters, mt.id, attacker)
		}
		msg := &MonsterDamaged{MonsterID: mt.id, Damage: int32(dmg), RemainingHP: int32(updated.HP)}
		for _, e := range watchers {
			sendMonsterPush(e.Session, &proto.Packet{Opcode: OpMonsterDamaged, Data: msg.Encode()})
		}
		return nil
	}
	var killer int64
	if !mt.tick.SourceIsMonster && mt.tick.Credited(true) {
		killer = mt.tick.SourceID
	}
	// The kill's word to the nests (round 660, nestkill.go), as a killing
	// blow's (performAttack): the killer's party near the monster may arm its
	// nest for a party monster. The killer is the applier the tick is booked
	// to (statuseffect.SourceRule, READ), 0 when it names nobody -- which
	// counts no party. Round 666: until then a DoT kill never armed a nest.
	noteMonsterKilled(d.hub, d.parties, hits, updated)
	s.forgetMonster(mt.id)
	return s.settleKill(ctx, d, statusKill{monster: m, killer: killer, damage: dmg, updated: updated, hits: hits}, watchers)
}

// dealCharacterTick deals one tick to a character and, when it leaves her at
// 0, completes the death as a monster's blow would: finishKill (the lock, the
// penalty, the dead state or the respawn), then the same OpMonsterAttacked a
// killing blow sends, to her and her zone, flagged StrikeStatusTick so no
// client draws a swing (round 659's review, H3: before it she was told only
// her new HP, and never entered the dead state). It reports whether she died.
func (s *statusRuntime) dealCharacterTick(ctx context.Context, d strikeDeps, st RegenDeps, ct characterTick) bool {
	if d.chars == nil || deadCharacter(d.hub, ct.id) {
		return true
	}
	dmg := ct.tick.Damage
	if ct.tick.NeverKills {
		c, err := d.chars.GetByID(ctx, ct.id)
		if err != nil || c == nil {
			return false
		}
		if dmg = min(dmg, c.HP-1); dmg <= 0 {
			return false
		}
	}
	left, _, err := d.chars.ApplyDamage(ctx, ct.id, dmg)
	if err != nil {
		return false
	}
	s.tracef("status: character %d %s tick %d (HP %d)", ct.id, ct.tick.Code, dmg, left)
	if left > 0 {
		pushStats(ctx, d, st, ct.id)
		return false
	}
	out, err := finishKill(ctx, d, ct.id, monsterStrikeOutcome{damage: dmg})
	if err != nil {
		if s.logger != nil {
			s.logger.Warn("status: a character's death by a tick", "character", ct.id, "err", err)
		}
		return true
	}
	s.tracef("status: character %d died of a %s tick (dropped %v, exp lost %d)", ct.id, ct.tick.Code, out.dropped, out.deathExpLost)
	if out.dropped {
		return true // another kill got there first and reported itself
	}
	var monsterID int64
	if ct.tick.SourceIsMonster {
		monsterID = ct.tick.SourceID
	}
	// Every monster fighting her lets go, as the strike worker's kill makes
	// its killer let go (a.kills, battleTick): without -player-dead-state she
	// is back on her feet at once, and a monster in BATTLE on her would
	// otherwise never release (the re-review's MEDIUM).
	releaseTargetsOf(ct.id)
	msg := out.message(monsterID, ct.id)
	msg.StatusTick = true
	p := &proto.Packet{Opcode: OpMonsterAttacked, Data: msg.Encode()}
	if e, ok := entityOf(d.hub, ct.id); ok {
		for _, o := range d.hub.ViewOfCharacter(e.CharacterID) {
			if o.Session != nil {
				sendMonsterPush(o.Session, p)
			}
		}
	}
	// Flag off, the tick's kill respawned her: to the return point, after
	// the push (round 665, returnAfterKill).
	returnAfterKill(ctx, d.chars, d.eq, d.hub, ct.id)
	return true
}

// releaseTargetsOf marks, for every monster in BATTLE on characterID, the
// kill battleTick releases a monster on (a.kills) -- what runStrike records
// for the monster whose blow killed her. A no-op with the AI off.
func releaseTargetsOf(characterID int64) {
	a := monsterAIRuntime.Load()
	if a == nil {
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	for id, b := range a.brains {
		if b.target == characterID && b.machine.State() == ai.StateBattle {
			a.kills[id] = struct{}{}
		}
	}
}

// endCharacter ends a character's states at her death (finishKill) and tells
// her zone the mask is empty.
func (s *statusRuntime) endCharacter(hub *world.Hub, characterID int64) {
	s.mu.Lock()
	h := s.pcs[characterID]
	delete(s.pcs, characterID)
	s.mu.Unlock()
	if h == nil || h.Empty() {
		return
	}
	if e, ok := entityOf(hub, characterID); ok {
		broadcastStatus(hub, e.Zone, &ObjectStatus{OwnerKind: OwnerCharacter, OwnerID: characterID})
	}
}

// statusKill is a monster killed by a state's tick.
type statusKill struct {
	monster combat.Monster
	killer  int64 // 0: nobody is credited
	damage  int
	// updated and hits are damageMonsterWatched's for the killing tick: the
	// unique kill notice reads them (AnnounceUniqueKill).
	updated combat.Monster
	hits    []combat.Hit
}

// settleKill pays a monster's death by a tick: grantKill, exactly as a killing
// blow (round 659's refactor of performAttack's kill branch), then
// announceKill to the WHOLE zone -- there is no OpAttackResult to tell the
// killer, so the killer is sent OpMonsterDied too -- and OpLevelUp to the
// killer when the kill crossed a level. watchers are damageMonsterWatched's:
// the players whose window held the monster before or after the tick. A
// killer who has left the world is paid nothing and the death is still
// announced (OURS).
func (s *statusRuntime) settleKill(ctx context.Context, d combatDeps, k statusKill, watchers []world.Entity) error {
	chanceMemory.Forget(k.monster.ID)
	zone := watchers
	var sess *gateway.Session
	if e, ok := entityOf(d.hub, k.killer); ok && k.killer != 0 {
		sess = e.Session
	}
	if sess == nil {
		msg := &MonsterDied{MonsterID: k.monster.ID}
		for _, e := range zone {
			sendMonsterPush(e.Session, &proto.Packet{Opcode: OpMonsterDied, Data: msg.Encode()})
		}
		AnnounceUniqueKill(d.hub, d.parties, k.updated, k.hits)
		// The death still pays everyone else its damage list earns a share
		// (round 712): the distributor does not depend on who dealt the last
		// tick, and the absent killer drops out with presentHits.
		if levelTable.Loaded() {
			if _, err := distributeKill(ctx, d, 0, k.monster, k.hits); err != nil {
				return err
			}
		}
		return nil
	}
	result := &AttackResult{MonsterID: k.monster.ID, MonsterDamage: int32(k.damage), MonsterDied: true}
	levelUp, gold, err := grantKill(ctx, d, k.killer, k.monster, result, k.hits)
	if err != nil {
		return err
	}
	s.tracef("status: monster %d killed by a tick, credited to character %d (exp %d, gold %d)", k.monster.ID, k.killer, result.ExpGained, gold)
	if levelUp != nil {
		sess.Send(&proto.Packet{Opcode: OpLevelUp, Data: levelUp.Encode()})
	}
	if result.expGain != nil {
		sendExpGainTo(sess, *result.expGain) // round 716: last, as in combat.go
	}
	return announceKill(ctx, d, sess, zone, k.killer, k.monster, gold, k.updated, k.hits)
}

// pushStats sends a character the stats reply the HUD paints its bar from
// (regen.go's push), after a tick moved her HP.
func pushStats(ctx context.Context, d strikeDeps, st RegenDeps, characterID int64) {
	e, ok := entityOf(d.hub, characterID)
	if !ok || e.Session == nil || d.chars == nil {
		return
	}
	c, err := d.chars.GetByID(ctx, characterID)
	if err != nil || c == nil {
		return
	}
	eq, items, mp := st.Equipment, st.Items, st.Mana
	if eq == nil {
		eq, items, mp = d.eq, d.items, d.mp
	}
	res, err := buildCharacterStats(ctx, c, characterID, eq, items, st.Skills, mp)
	if err != nil {
		return
	}
	e.Session.Send(&proto.Packet{Opcode: OpCharacterStatsResult, Data: res.Encode()})
}

// broadcastStatus sends msg to every session in zone -- for a character's,
// since round 737, to the players in view that hold its body and to itself
// (sendAboutOwner); one arriving later is sent it with the spawn
// (characterStatusFrame).
func broadcastStatus(hub *world.Hub, zone string, msg *ObjectStatus) {
	if hub == nil || msg == nil {
		return
	}
	if msg.OwnerKind == OwnerCharacter {
		sendAboutOwner(zoneOf(hub, msg.OwnerID), msg.OwnerID, OpObjectStatus, msg.Encode())
		return
	}
	p := &proto.Packet{Opcode: OpObjectStatus, Data: msg.Encode()}
	for _, e := range hub.EntitiesInZone(zone) {
		if e.Session != nil {
			e.Session.Send(p)
		}
	}
}

// characterStatusFrame is a character's abnormal states as the OpObjectStatus
// a client that spawns it is sent after the spawn (round 737's review, F7),
// or nil when it has none.
func characterStatusFrame(id int64) *gateway.Frame {
	statusFX.mu.Lock()
	var msg *ObjectStatus
	if h := statusFX.pcs[id]; h != nil && !h.Empty() {
		msg = &ObjectStatus{OwnerKind: OwnerCharacter, OwnerID: id, Mask: h.Mask(), Levels: h.Levels()}
	}
	statusFX.mu.Unlock()
	if msg == nil {
		return nil
	}
	return gateway.MustFrame(&proto.Packet{Opcode: OpObjectStatus, Data: msg.Encode()})
}

// monsterStatusPacket is a monster's mask as an OpObjectStatus, or nil when
// it has none. The area of interest's enter (sendMonsterEnter) and the
// monster list (handleMonsterList) put it in their own batch, under the
// session's monster wire lock, so a monster that comes into view already
// stunned is drawn stunned, and nothing comes between its enter, its status
// and its leg (round 662's review: a builder, not a Send, so the caller
// queues the sequence as one SendBatch).
func monsterStatusPacket(id int64) *proto.Packet {
	statusFX.mu.Lock()
	var msg *ObjectStatus
	if h := statusFX.mobs[id]; h != nil && !h.Empty() {
		msg = &ObjectStatus{OwnerKind: OwnerMonster, OwnerID: id, Mask: h.Mask(), Levels: h.Levels()}
	}
	statusFX.mu.Unlock()
	if msg == nil {
		return nil
	}
	return &proto.Packet{Opcode: OpObjectStatus, Data: msg.Encode()}
}

// statusPacketsOfList is what follows a monster list: the masks of the
// monsters it named and of every character in the zone (characters are
// zone-wide in OpenSRO's view; OURS). handleMonsterList appends them to the
// list's own batch, under the session's monster wire lock.
func statusPacketsOfList(hub *world.Hub, listed []combat.Monster, zone string) []*proto.Packet {
	var out []*proto.Packet
	for _, m := range listed {
		if p := monsterStatusPacket(m.ID); p != nil {
			out = append(out, p)
		}
	}
	if hub == nil {
		return out
	}
	statusFX.mu.Lock()
	ids := make([]int64, 0, len(statusFX.pcs))
	msgs := make(map[int64]*ObjectStatus, len(statusFX.pcs))
	for id, h := range statusFX.pcs {
		if !h.Empty() {
			ids = append(ids, id)
			msgs[id] = &ObjectStatus{OwnerKind: OwnerCharacter, OwnerID: id, Mask: h.Mask(), Levels: h.Levels()}
		}
	}
	statusFX.mu.Unlock()
	for _, id := range ids {
		if e, ok := hub.EntityByCharacterID(id); ok && e.Zone == zone {
			out = append(out, &proto.Packet{Opcode: OpObjectStatus, Data: msgs[id].Encode()})
		}
	}
	return out
}

// RunStatusEffects steps every object's states every StatusTick until ctx
// ends. cmd/server starts it once; deps are what the stats push after a
// damage tick reads, as RunRegen's.
func RunStatusEffects(ctx context.Context, logger *slog.Logger, deps RegenDeps, monsters *combat.Hub) {
	statusFX.mu.Lock()
	statusFX.logger, statusFX.stats = logger, deps
	if monsters != nil {
		statusFX.mons = monsters
	}
	statusFX.mu.Unlock()
	t := time.NewTicker(StatusTick)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-t.C:
			statusFX.step(ctx, now)
		}
	}
}

// heldByStatus is the monster AI's gate (monsterai.go update): a monster its
// states stop from acting does nothing this tick, and one they stop from
// moving has its leg ended where it stands. READ/INFERRED as Holder.CanMove
// and Holder.CanAct say.
//
// Its speed changes at once, too (round 659's review, L3): frostbite's and
// slow's appliers republish the speed on apply and on removal (vslots
// 0x4e8/0x4ec after the params, READ), so a monster on a leg whose speed no
// longer matches its states has the leg restarted from where it stands at
// the right speed, which puts a new OpMonsterMoved on the wire.
func (a *monsterAI) heldByStatus(b *brain) bool {
	move, act, pct := statusFX.monsterState(b.id)
	if !move && b.m.Moving {
		if m, ok := a.monsters.StopMotion(b.id); ok {
			b.m = m
			a.queueStop(m)
		}
	}
	if move && b.m.Moving && statusFX.legPercent(b.id) != pct {
		a.startLeg(b, b.m.DestX, b.m.DestZ, b.m.MoveMode, "status speed")
	}
	return !act
}

// legPercent is the speed percent monster id's current leg was started at
// (statusSpeed), 100 when no state touched it.
func (s *statusRuntime) legPercent(id int64) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	if p, ok := s.legPct[id]; ok {
		return p
	}
	return 100
}

// statusSpeed scales a leg's speed by the monster's states (monsterai.go
// startLeg), and says whether it may start one at all.
func statusSpeed(id int64, speed float64) (float64, bool) {
	move, _, pct := statusFX.monsterState(id)
	statusFX.mu.Lock()
	if pct == 100 {
		delete(statusFX.legPct, id)
	} else {
		statusFX.legPct[id] = pct
	}
	statusFX.mu.Unlock()
	return speed * float64(pct) / 100, move
}

func (s *statusRuntime) tracef(format string, args ...any) {
	if s.logger != nil {
		s.logger.Debug("status", "line", fmt.Sprintf(format, args...))
	}
}

func codesOf(recs []statuseffect.Record) []string {
	out := make([]string, 0, len(recs))
	for _, r := range recs {
		out = append(out, r.Code)
	}
	return out
}

func monsterOf(h *combat.Hub, id int64) (combat.Monster, bool) {
	if h == nil {
		return combat.Monster{}, false
	}
	return h.Get(id)
}

func entityOf(hub *world.Hub, characterID int64) (world.Entity, bool) {
	if hub == nil {
		return world.Entity{}, false
	}
	return hub.EntityByCharacterID(characterID)
}
