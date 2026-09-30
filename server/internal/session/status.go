package session

// Monsters give and receive status effects (round 659).
//
// internal/statuseffect holds the rules, each READ out of SR_GameServer.exe
// and cited there: how a skill's status run lands (statuseffect.Resolve), one
// record per slot (Holder.Put), the pass that expires and ticks them
// (Holder.Step), and what a state stops (CanMove, CanAct, SpeedPercent). This
// file wires them to srrevamp's objects:
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

	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
	"github.com/OpenSRO/srrevamp/server/internal/statuseffect"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// OpObjectStatus is an object's abnormal-state mask, server -> every session
// in the object's zone. The number is retail's 0x3057, and the payload is
// that message's flag-4 block (sro_client.exe's handler 0x8a9e30:
// `if (flags & 4) { Read(mask, 4); 0x9cd5e0(mask); 0x9d2220(mask, stream) }`,
// the second reading one level byte for each set bit in
// statuseffect.LevelBits, low bit first). READ, the block. OURS, the head:
// srrevamp names an object by (owner kind, int64 id) where retail sends a u32
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

// Encode writes the payload (little-endian, as every srrevamp message).
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
	// bound by the first player cast that applies a state; sdeps what a
	// character's death by a tick goes through (finishKill), bound by the
	// first monster blow that does. Both are the process's one set of stores.
	cdeps combatDeps
	sdeps strikeDeps
	// stats are the stores the stats push reads (RunStatusEffects' deps,
	// regen.go's shape), so a bar a tick moved keeps its SP and MP lines.
	stats  RegenDeps
	epoch  time.Time
	logger *slog.Logger
}

func newStatusRuntime() *statusRuntime {
	return &statusRuntime{mobs: map[int64]*statuseffect.Holder{}, pcs: map[int64]*statuseffect.Holder{}, epoch: time.Now()}
}

// statusFX is the process's runtime, package-level like buffBooks and
// chanceMemory: the states belong to the objects, not to one request.
var statusFX = newStatusRuntime()

// ms is t on the runtime's millisecond clock (GetTickCount's shape: a uint32
// that the engine's comparisons subtract, so a wrap is harmless).
func (s *statusRuntime) ms(t time.Time) uint32 {
	return uint32(t.Sub(s.epoch) / time.Millisecond)
}

// statusRoller is the chance-memory dice for one target: the same
// accumulators and generator as a blow's critical and block, under a kind of
// their own per state (combat.ChanceStatus).
func statusRoller(targetID int64) statuseffect.Roller {
	return func(chance, kind int) bool {
		damageRollMu.Lock()
		defer damageRollMu.Unlock()
		return combat.RollChanceTracked(chance, damageRollNG, chanceMemory, targetID, combat.ChanceStatus(kind))
	}
}

// applyToMonster lands castRow's status runs on monsterID, cast by
// characterID, and tells the zone when the mask changed.
func (s *statusRuntime) applyToMonster(d combatDeps, characterID int64, castRow *refdata.Skill, monsterID int64, now time.Time) {
	if castRow == nil || castRow.StatusParams == "" || d.monsters == nil {
		return
	}
	runs := statuseffect.ParseRuns(castRow.StatusParams)
	if len(runs) == 0 {
		return
	}
	m, ok := d.monsters.Get(monsterID)
	if !ok || m.HP <= 0 {
		return
	}
	// A monster resists nothing: characterdata cols 61-66 read 0 on every
	// row (MEASURED), so the resist arrays stay zero.
	recs := statuseffect.ResolveAll(runs, statuseffect.Target{Level: m.Level}, s.ms(now), statusRoller(monsterID))
	if len(recs) == 0 {
		return
	}
	s.mu.Lock()
	s.cdeps = d
	h := s.mobs[monsterID]
	if h == nil {
		h = &statuseffect.Holder{}
		s.mobs[monsterID] = h
	}
	before := h.Mask()
	for _, r := range recs {
		r.SourceID = characterID
		h.Put(r)
	}
	msg := &ObjectStatus{OwnerKind: OwnerMonster, OwnerID: monsterID, Mask: h.Mask(), Levels: h.Levels()}
	s.mu.Unlock()
	s.tracef("status: monster %d took %v from character %d (mask %#x -> %#x)", monsterID, codesOf(recs), characterID, before, msg.Mask)
	if !canAct(msg.Mask) || !canMove(msg.Mask) {
		// The applier stops the move at once (vslot 0x570, READ); the AI's
		// next tick sends the stop (heldByStatus).
		d.monsters.StopMotion(monsterID)
	}
	pushMonsterStatus(d.hub, d.monsters, m, msg)
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
// on a dead character: Combat_ApplyStatusEffects returns at once for a target
// whose life state is not alive (its prologue, 0x5906c0 `cmp [edi+5],2`), and
// so does this.
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
	// by srrevamp, so every character resists nothing for now.
	now := time.Now()
	recs := statuseffect.ResolveAll(runs, statuseffect.Target{Level: c.Level}, s.ms(now), statusRoller(characterID))
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
	s.mu.Unlock()
	s.tracef("status: character %d took %v from monster %d (mask %#x)", characterID, codesOf(recs), monster.ID, msg.Mask)
	if e, ok := entityOf(d.hub, characterID); ok {
		broadcastStatus(d.hub, e.Zone, msg)
	}
}

// monsterMayAct reports whether monsterID's states let it strike (the
// synchronous counter in performAttack).
func monsterMayAct(id int64) bool {
	_, act, _ := statusFX.monsterState(id)
	return act
}

func canMove(mask uint32) bool { return mask&(0xc1|0x4000) == 0 }

// canAct mirrors Holder.CanAct on a mask: freeze 0x1, sleep 0x40, stun 0x4000.
func canAct(mask uint32) bool { return mask&(0x1|0x40|0x4000) == 0 }

// monsterState reports what monsterID's states allow: moving, acting, and the
// speed percent of its next leg.
func (s *statusRuntime) monsterState(id int64) (move, act bool, speed int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	h := s.mobs[id]
	if h == nil {
		return true, true, 100
	}
	return h.CanMove(), h.CanAct(), h.SpeedPercent()
}

// addHeld adds to insistent every monster with a brain whose states stop it
// from moving or acting: under -monster-sleep (round 656) such a monster is
// kept awake, as one in BATTLE or HOMING is, so its stop and its release are
// the tick's and not frozen part-way. The monster AI calls it under its lock.
func (s *statusRuntime) addHeld(insistent map[int64]struct{}, brains map[int64]*brain) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for id, h := range s.mobs {
		if _, ok := brains[id]; ok && (!h.CanMove() || !h.CanAct()) {
			insistent[id] = struct{}{}
		}
	}
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
	s.mu.Unlock()
}

// monsterTick is one damage tick on a monster, computed under the runtime's
// lock and dealt after it.
type monsterTick struct {
	zone   string
	id     int64
	tick   statuseffect.Tick
	killer int64 // the character a fatal tick pays; 0 nobody
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

// step is one pass over every holder at now. Under the runtime's lock it only
// expires and ticks the records (Holder.Step) and notes what to deal and what
// to announce; the damage, the kills and the sends happen after it, outside
// the lock -- the monster AI's tick reads the runtime under its own lock
// (heldByStatus), so this pass never holds ours while it takes another.
func (s *statusRuntime) step(ctx context.Context, now time.Time) {
	nowMs := s.ms(now)
	var pushes []statusPush
	var mticks []monsterTick
	var cticks []characterTick

	s.mu.Lock()
	cd, sd, st := s.cdeps, s.sdeps, s.stats
	for id, h := range s.mobs {
		m, ok := monsterOf(cd.monsters, id)
		if !ok || m.HP <= 0 {
			delete(s.mobs, id)
			continue
		}
		ticks, changed := h.Step(nowMs, m.HP)
		for _, t := range ticks {
			mt := monsterTick{zone: m.Zone, id: id, tick: t}
			if t.Credited && !t.SourceIsMonster {
				mt.killer = t.SourceID
			}
			mticks = append(mticks, mt)
		}
		if changed {
			pushes = append(pushes, statusPush{monster: true, zone: m.Zone, msg: &ObjectStatus{OwnerKind: OwnerMonster, OwnerID: id, Mask: h.Mask(), Levels: h.Levels()}})
		}
		if h.Empty() {
			delete(s.mobs, id)
		}
	}
	for id, h := range s.pcs {
		e, inWorld := entityOf(sd.hub, id)
		hp, alive := 0, false
		if sd.chars != nil && inWorld && e.Life != world.LifeDead {
			if c, err := sd.chars.GetByID(ctx, id); err == nil && c != nil && c.HP > 0 {
				hp, alive = c.HP, true
			}
		}
		if !alive {
			// Dead, or gone from the world: the states end (OURS for the
			// logout; a death clears them as a monster's does).
			if h.EndAll() && inWorld {
				pushes = append(pushes, statusPush{zone: e.Zone, msg: &ObjectStatus{OwnerKind: OwnerCharacter, OwnerID: id}})
			}
			delete(s.pcs, id)
			continue
		}
		ticks, changed := h.Step(nowMs, hp)
		for _, t := range ticks {
			cticks = append(cticks, characterTick{id: id, tick: t})
		}
		if changed {
			pushes = append(pushes, statusPush{zone: e.Zone, msg: &ObjectStatus{OwnerKind: OwnerCharacter, OwnerID: id, Mask: h.Mask(), Levels: h.Levels()}})
		}
		if h.Empty() {
			delete(s.pcs, id)
		}
	}
	s.mu.Unlock()

	hub := cd.hub
	if hub == nil {
		hub = sd.hub
	}
	for _, p := range pushes {
		if p.monster {
			if m, ok := monsterOf(cd.monsters, p.msg.OwnerID); ok {
				pushMonsterStatus(hub, cd.monsters, m, p.msg)
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
		if _, alive := monsterOf(cd.monsters, mt.id); !alive {
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
// A poison tick is clamped against the HP the monster has NOW: it never
// kills (statuseffect.PoisonTickDamage), and a blow may have landed since the
// pass read its HP.
func (s *statusRuntime) dealMonsterTick(ctx context.Context, d combatDeps, mt monsterTick) error {
	dmg := mt.tick.Damage
	if mt.tick.Code == "ps" {
		m, ok := monsterOf(d.monsters, mt.id)
		if !ok {
			return nil
		}
		if dmg = min(dmg, m.HP-1); dmg <= 0 {
			return nil
		}
	}
	before, _ := monsterOf(d.monsters, mt.id)
	// Booked on the monster's damage list (round 657) to the tick's source
	// only when the engine keeps one: a fatal burn or bleeding tick names its
	// applier, which is how a kill by a tick is credited -- the unique notice
	// included; a non-fatal tick and every poison tick drop the source (READ,
	// the appliers 0x4a46f0 / 0x4a4cc0 / 0x4a4940), so they book nobody.
	updated, died, ok, watchers, hits := damageMonsterWatched(d.hub, d.monsters, mt.id, mt.killer, dmg)
	if !ok {
		return nil
	}
	s.tracef("status: monster %d %s tick %d (HP %d)", mt.id, mt.tick.Code, dmg, updated.HP)
	if !died {
		msg := &MonsterDamaged{MonsterID: mt.id, Damage: int32(dmg), RemainingHP: int32(updated.HP)}
		for _, e := range watchers {
			sendMonsterPush(e.Session, &proto.Packet{Opcode: OpMonsterDamaged, Data: msg.Encode()})
		}
		return nil
	}
	s.forgetMonster(mt.id)
	return s.settleKill(ctx, d, statusKill{monster: before, killer: mt.killer, damage: dmg, updated: updated, hits: hits}, watchers)
}

// dealCharacterTick deals one tick to a character and, when it leaves her at
// 0, completes the death as a monster's blow would (finishKill). It reports
// whether she died.
func (s *statusRuntime) dealCharacterTick(ctx context.Context, d strikeDeps, st RegenDeps, ct characterTick) bool {
	if d.chars == nil || deadCharacter(d.hub, ct.id) {
		return true
	}
	dmg := ct.tick.Damage
	if ct.tick.Code == "ps" {
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
	pushStats(ctx, d, st, ct.id)
	return true
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
		return nil
	}
	result := &AttackResult{MonsterID: k.monster.ID, MonsterDamage: int32(k.damage), MonsterDied: true}
	levelUp, gold, err := grantKill(ctx, d, k.killer, k.monster, result)
	if err != nil {
		return err
	}
	s.tracef("status: monster %d killed by a tick, credited to character %d (exp %d, gold %d)", k.monster.ID, k.killer, result.ExpGained, gold)
	if levelUp != nil {
		sess.Send(&proto.Packet{Opcode: OpLevelUp, Data: levelUp.Encode()})
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

// broadcastStatus sends msg to every session in zone.
func broadcastStatus(hub *world.Hub, zone string, msg *ObjectStatus) {
	if hub == nil || msg == nil {
		return
	}
	p := &proto.Packet{Opcode: OpObjectStatus, Data: msg.Encode()}
	for _, e := range hub.EntitiesInZone(zone) {
		if e.Session != nil {
			e.Session.Send(p)
		}
	}
}

// sendMonsterStatus writes a monster's mask to sess when it has one: the
// area of interest's enter (sendMonsterEnter) and the monster list call it,
// both under the session's monster wire lock, so a monster that comes into
// view already stunned is drawn stunned.
func sendMonsterStatus(sess *gateway.Session, id int64) error {
	statusFX.mu.Lock()
	var msg *ObjectStatus
	if h := statusFX.mobs[id]; h != nil && !h.Empty() {
		msg = &ObjectStatus{OwnerKind: OwnerMonster, OwnerID: id, Mask: h.Mask(), Levels: h.Levels()}
	}
	statusFX.mu.Unlock()
	if msg == nil || sess == nil {
		return nil
	}
	return sess.Send(&proto.Packet{Opcode: OpObjectStatus, Data: msg.Encode()})
}

// sendStatusesOfList follows a monster list with the masks of the monsters it
// named and of every character in the zone (characters are zone-wide in
// srrevamp's view; OURS). The caller holds the session's monster wire lock.
func sendStatusesOfList(sess *gateway.Session, hub *world.Hub, listed []combat.Monster, zone string) {
	for _, m := range listed {
		if sendMonsterStatus(sess, m.ID) != nil {
			return
		}
	}
	if hub == nil || sess == nil {
		return
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
			if sess.Send(&proto.Packet{Opcode: OpObjectStatus, Data: msgs[id].Encode()}) != nil {
				return
			}
		}
	}
}

// RunStatusEffects steps every object's states every StatusTick until ctx
// ends. cmd/server starts it once; deps are what the stats push after a
// damage tick reads, as RunRegen's.
func RunStatusEffects(ctx context.Context, logger *slog.Logger, deps RegenDeps) {
	statusFX.mu.Lock()
	statusFX.logger, statusFX.stats = logger, deps
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
func (a *monsterAI) heldByStatus(b *brain) bool {
	move, act, _ := statusFX.monsterState(b.id)
	if !move && b.m.Moving {
		if m, ok := a.monsters.StopMotion(b.id); ok {
			b.m = m
			a.queueStop(m)
		}
	}
	return !act
}

// statusSpeed scales a leg's speed by the monster's states (monsterai.go
// startLeg), and says whether it may start one at all.
func statusSpeed(id int64, speed float64) (float64, bool) {
	move, _, pct := statusFX.monsterState(id)
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
