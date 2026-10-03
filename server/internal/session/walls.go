package session

// The toggles and the protection walls (round 640; docs/protocol/
// skill_buffs.md "The toggles" and "The protection walls"). Fire Wall
// (SKILL_CH_FIRE_HWABYEOK_*) and Crystal Wall (SKILL_CH_COLD_BINGBYEOK_*) are
// action-kind-3 toggles with no 'dura': 'onff' drains their MP and 'pw'
// raises a wall that takes the blows of the damage type it covers in the
// caster's place until its own HP runs out. The Bard songs and dances carry
// 'onff' too and drain the same way.
//
// READ in SR_GameServer.exe, and where:
//
//   - the wall: EngageSkill (0x593540) builds it (HP = 'pw' value[1]) and
//     makes it the owner's (pc+0xc0c) and sets the motion state 0x11
//     SKILL_PROTECTIONWALL; Combat_ResolveDamage (0x58e5f0) computes the
//     blow against the wall's own defence ('pw' value[2]/value[3]) and, when
//     the types agree, the caster's own entry takes nothing;
//     Combat_ApplyActionEffects (0x593800) takes the damage off the wall's
//     HP; SkillAction_Buff's sub-state 2 ends the record once it is 0.
//   - the drain: SkillAction_Buff's sub-state 2 (0x585250..0x5852cc) takes
//     onff[1] MP every onff[0] ms and ends the toggle when the MP is short.
//   - the toggle: Tick_UseSkill's phase 0 (0x4ae590) ends a running 'onff'
//     record of the skill instead of casting it again.
//
// NOT found in either binary: anything that stops a walled caster from
// moving. The server's movement handler (GObjPC::FUN_004b0ea0, CGObjPC's
// slot 377) refuses motion states 8, 0x10 and 0x12 and the 'stns' stun
// holder pc+0xc44, not 0x11; the client's move gates (the body-state mask
// FUN_009eb140 & 0x2476, the 500 ms send lock, the modal UI) read neither
// 'pw' nor 'onff'. docs/protocol/skill_buffs.md has the probes.
//
// THE ROOT IS OURS (round 640, the user's choice "Root while walled", asked
// after the probes above came back empty): while a 'pw' wall record is
// active its caster's moves are dropped (handleMove -> motions.moved), and
// the dropped move is answered with the position the server holds
// (rootedMoveAnswer) so a client whose walk was cut short by the wall snaps
// back rather than drifting out of step. Attacks and skills are not touched:
// the ordinary reach rules decide them. (Ghost Walk is refused while walled
// by retail's own gate -- READ, not the root: wallTeleRefusal.) Whatever ends the record
// (a cancel, a recast, the wall's HP, the MP drain, a death, a logout) ends
// the root with it.

import (
	"context"
	"log/slog"
	"math"
	"sync"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/buff"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
	"github.com/OpenSRO/OpenSRO/server/internal/worldmap"
)

// MotionProtectionWall is MOTIONSTATE_SKILL_PROTECTIONWALL (0x11, the
// engine's table at .rdata 0x00c63f90): EngageSkill sets it for a 'pw' row
// through SetMotionState(0x11, 0xff, 0) -- which broadcasts nothing (0x4a9d00
// sends only through AJStateChanger, taken when the second argument is not
// 0xff). What it does here: the skill gate refuses an 'ao'/'pw' row in it
// (0x58e0cb), the sit request (FUN_004b1480) refuses from it, and the regen
// tick restores nothing in it (CGObjPC::vslot_362 regenerates only in STAND
// and SIT) -- all three READ.
const MotionProtectionWall byte = 0x11

// wallRoots reports whether characterID is rooted by its own wall (OURS,
// see the package note above): a 'pw' record is active on its book.
func wallRoots(characterID int64) bool {
	return buffBooks.HoldsWall(characterID)
}

// rootedMoveAnswer answers a move the root dropped (OURS): OpSkillMove to
// the mover's own session only, carrying the wall's skill id and the
// position the server holds, which the client takes as "stay here"
// (World3D._on_skill_moved). Retail sends no such thing -- it has no root.
func rootedMoveAnswer(sess *gateway.Session, e world.Entity) {
	rec, ok := buffBooks.WallRecord(e.CharacterID)
	if !ok || sess == nil {
		return
	}
	msg := &SkillMove{CharacterID: e.CharacterID, SkillID: rec.SkillID,
		X: float32(e.Pos.X), Y: float32(e.Pos.Y), Z: float32(e.Pos.Z)}
	_ = sess.Send(&proto.Packet{Opcode: OpSkillMove, Data: msg.Encode()})
}

// warpLandings holds, per rooted character, the one relocated move that is
// its warp's landing (round 646, OURS -- the root is OURS too). A zone change
// or a gate teleport lands the character at the server's arrival point, and
// the client then stands it on its own walkable ground (the zone's spawn
// spot, a /goto's point, a gate's point on the graph) and reports that as a
// relocated OpMove -- the server has no map. The root dropped that report, so
// the server kept the arrival point while the client drew the caster
// elsewhere: every other player saw the walled caster, and its wall, where it
// was not (MEASURED live in round 646: A's client at the Jangan spawn, local
// 1002,1020, the server and B's client at the town's landing). A warp is not
// a walk; the root holds a caster in place, it does not hold it where it
// never stood.
//
// The review of round 646: the landing is ONE move, to a point the server
// itself named -- the warp's arrival, the client's own spawn spot in the
// arrival's region (worldmap.LandingSpotFor, the client's ZONE_SPAWN_LOCAL),
// or a GM /tp or /goto point -- within warpLandingTolerance on x and z (the
// height is the client's; the server has none). It is used up by the move it
// admits, and forgotten when the wall ends, on logout, and after the grace.
// Until the review any relocated move was taken for two minutes after any
// warp, wherever it went: a free walk for a walled caster.
var warpLandings sync.Map // int64 -> *warpLanding

// warpLanding is one pending landing: the points the server sent the caster
// to, and until when one of them is taken.
type warpLanding struct {
	points   [][2]float64
	deadline time.Time
}

// warpLandingGrace is how long after a warp its landing is taken. OURS: long
// enough for a slow machine's zone load (round 646's box took 5-18 s).
const warpLandingGrace = 2 * time.Minute

// warpLandingTolerance is how far, on x and on z, a landing may lie from the
// point it names. OURS: the client stands the player at the named x, z (the
// gate's point, the spawn spot, the GM's point -- MEASURED in round 646: the
// gate's local 957,1508 is the server's -28803,-10148 exactly); a float32 at
// the far towns' 170,880 units steps by 1/64, so one unit is room for the
// wire and the client's transform and nothing more.
const warpLandingTolerance = 1.0

// noteWarpLanding adds the points pts (x, z pairs) as characterID's warp
// landing, for the grace -- only while its wall roots it. A second warp
// inside the grace keeps the first's points (a GM /goto names its point,
// then the zone change its arrival).
func noteWarpLanding(characterID int64, now time.Time, pts ...[2]float64) {
	if !wallRoots(characterID) {
		warpLandings.Delete(characterID)
		return
	}
	l := &warpLanding{deadline: now.Add(warpLandingGrace)}
	if v, ok := warpLandings.Load(characterID); ok && now.Before(v.(*warpLanding).deadline) {
		l.points = append(l.points, v.(*warpLanding).points...)
	}
	l.points = append(l.points, pts...)
	warpLandings.Store(characterID, l)
}

// noteZoneWarpLanding is noteWarpLanding for a warp's arrival at pos in zone:
// the arrival itself (a gate's point, which the client stands the player at)
// and, when the client has a spawn spot in the zone's centre region, that
// spot (worldmap.LandingSpotFor).
func noteZoneWarpLanding(characterID int64, zone string, pos world.Position, now time.Time) {
	pts := [][2]float64{{pos.X, pos.Z}}
	if x, z, ok := worldmap.LandingSpotFor(zone, pos.X, pos.Z); ok {
		pts = append(pts, [2]float64{x, z})
	}
	noteWarpLanding(characterID, now, pts...)
}

// forgetWarpLanding drops a pending landing: the wall ended, or the
// character left the world.
func forgetWarpLanding(characterID int64) { warpLandings.Delete(characterID) }

// warpLandingAdmits reports whether a move to (x, z) is a rooted character's
// warp landing -- relocated, inside the grace, at one of the points the
// server named -- and uses the landing up when it is. A walk is never one.
func warpLandingAdmits(characterID int64, relocated bool, x, z float64, now time.Time) bool {
	if !relocated {
		return false
	}
	v, ok := warpLandings.Load(characterID)
	if !ok {
		return false
	}
	l := v.(*warpLanding)
	if now.After(l.deadline) {
		warpLandings.CompareAndDelete(characterID, v)
		return false
	}
	for _, p := range l.points {
		if math.Abs(x-p[0]) <= warpLandingTolerance && math.Abs(z-p[1]) <= warpLandingTolerance {
			return warpLandings.CompareAndDelete(characterID, v)
		}
	}
	return false
}

// wallTeleRefusal answers a 'tele'/'tel2'/'tel3' cast (Ghost Walk) while the
// caster's book holds a wall: READ, Skill_CheckUseConditions 0x58e033..
// 0x58e061 answers 0x3009 (round 640's review). The client's string for
// 0x3009 is not identified, so the wording is OURS.
const wallTeleRefusal = "cannot use that skill while a wall is up"

// wallStateRefusal answers an 'ao'/'pw' cast refused because its caster
// stands in SKILL_PROTECTIONWALL. The engine answers 0x3009 there, as for a
// sitter (the gate's one branch, 0x58e0a0..0x58e0ed); the client's text for
// 0x3009 is not identified, so the wording is OURS.
const wallStateRefusal = "cannot use that skill while a wall is up"

// wallSpec fills s's toggle and wall fields from ref: 'onff' from the buff
// parameter column, 'pw' from its own four columns.
func wallSpec(s *buff.Spec, ref *refdata.Skill) {
	if v, ok := ref.BuffParam("onff"); ok && len(v) >= 2 {
		s.HasOnff, s.OnffMs, s.OnffMP = true, v[0], v[1]
	}
	if ref.HasWall() {
		s.HasWall = true
		s.Wall = buff.Wall{Mask: uint32(ref.Pw0), HP: int(ref.Pw1), Def: int(ref.Pw2), DefPct: int(ref.Pw3)}
	}
}

// wallStarted is EngageSkill's SetMotionState(0x11, 0xff, 0) for a 'pw'
// record on ownerID.
func wallStarted(ownerID int64, rec buff.Record, now time.Time) {
	if rec.HasWall {
		motions.setWall(ownerID, now)
	}
}

// wallsEnded is SkillAction_BuffEnd's (and the break's) SetMotionState(0,
// 0xff, 0) for an ended 'pw' record: the owner stands. Neither broadcasts.
func wallsEnded(ownerID int64, ended []buff.Record) {
	for _, r := range ended {
		if r.HasWall {
			motions.endWall(ownerID, time.Now())
			// The root ends, and with it a pending landing (round 646's review).
			forgetWarpLanding(ownerID)
			return
		}
	}
}

// toggleOffOnCast is Tick_UseSkill's phase 0 for an 'onff' row (READ,
// 0x4ae590): when the caster already runs a record of the skill, its own
// cast, the record ends -- its token goes out as the ordinary OpBuffEnd --
// and the cast stops there: no gate, no cost, no cooldown, no cast
// broadcast (the 0x7070 of phase 2 that starts the cast is never posted).
// It reports whether it ended one.
func toggleOffOnCast(hub *world.Hub, casterID int64, ref *refdata.Skill) bool {
	if ref == nil {
		return false
	}
	if v, ok := ref.BuffParam("onff"); !ok || len(v) < 2 {
		return false
	}
	l := buffLock(casterID)
	l.Lock()
	defer l.Unlock()
	rec, sp, ok := buffBooks.ToggleOff(casterID, ref.ID)
	if !ok {
		return false
	}
	slog.Info("toggle: the recast switched it off", "character", casterID, "skill", ref.ID, "token", rec.Token)
	broadcastBuffEnd(zoneOf(hub, casterID), casterID, []buff.Record{rec}, sp)
	return true
}

// toggledOffResult answers the OpUseSkill a toggle-off consumed. The retail
// server answers the 0x7074 request with 0xB074 result 1 when it queues the
// action (before the tick ends the toggle) and sends no 0xB070, so the
// client draws no cast; OpenSRO's request has one reply, and this one
// carries no error, no costs and no blow. OURS: the marker Error text is
// empty and ToggledOff tells the client not to draw a cast.
func toggledOffResult(req *UseSkillRequest, hp int32) *AttackResult {
	r := echoed(req, &AttackResult{PlayerHP: hp})
	r.Wall.ToggledOff = true
	return r
}

// endBrokenWall ends ownerID's wall once its HP is 0 and tells the zone:
// the sub-state 2 tail (buff.Books.EndBrokenWalls). Retail's book update runs
// it on the next server frame after the blow, so the blow's packet goes
// first; OpenSRO runs it right after the messages that report the breaking
// blow (performAttack's counter, the AI's strike), and the toggle ticker
// catches any other within its poll.
func endBrokenWall(hub *world.Hub, ownerID int64) {
	endBrokenWallBy(hub, ownerID, time.Now())
}

// endBrokenWallBy ends ownerID's walls broken at or before cutoff.
func endBrokenWallBy(hub *world.Hub, ownerID int64, cutoff time.Time) {
	l := buffLock(ownerID)
	l.Lock()
	defer l.Unlock()
	ended, sp := buffBooks.EndBrokenWalls(ownerID, cutoff)
	if len(ended) > 0 {
		slog.Info("wall: broken, ended", "character", ownerID, "skill", ended[0].SkillID, "token", ended[0].Token)
		broadcastBuffEnd(zoneOf(hub, ownerID), ownerID, ended, sp)
	}
}

// monsterSkillRefs resolves a monster skill's 'att' mask for the wall test.
// cmd/server sets it once at boot (SetMonsterSkillRefs); nil leaves every
// monster blow of an unknown type.
var monsterSkillRefs SkillRefStore

// SetMonsterSkillRefs gives the wall test the skill table the monster
// skills' 'att' masks come from.
func SetMonsterSkillRefs(s SkillRefStore) { monsterSkillRefs = s }

// monsterBlowType is the 'att' value[0] of the skill monster swings: skill
// itself when named, else the monster's primary range's -- the col-83
// skill's, which OpenSRO knows only through its range: the first of the
// monster's skills whose AttMin/AttMax are the monster's own (INFERRED; the
// Jangan ladder's primaries match that way, cmd/server). A mask with neither
// bit 4 nor bit 8 known -- no table, an export predating the column -- is
// taken as physical, the reading combat.AttackType already gives a 0 (OURS,
// as it is there).
func monsterBlowType(ctx context.Context, monster combat.Monster, skill combat.MonsterSkill) uint32 {
	id := skill.ID
	if id == 0 {
		for _, s := range monster.Skills {
			if s.AttMin == monster.AttackMin && s.AttMax == monster.AttackMax {
				id = s.ID
				break
			}
		}
	}
	var t combat.AttackType
	if id != 0 && monsterSkillRefs != nil {
		if ref, err := monsterSkillRefs.GetSkill(ctx, id); err == nil && ref != nil {
			t = combat.AttackType(ref.AttackType)
		}
	}
	if !t.Known() {
		return buff.TypePhysical
	}
	return uint32(t)
}

// WallInfo is a blow's meeting with a protection wall, carried on the two
// messages a monster's blow reaches the client by (OpAttackResult's counter
// and OpMonsterAttacked) as a strict suffix, sent only when non-zero: u8 flags (WallAbsorbed,
// WallBroke, WallCritical, WallToggledOff), i32 the damage the wall took,
// i32 the wall's HP left, i32 its maximum. Retail's damage entry of kind 7
// carries the same three numbers (FUN_00a55e00: u32 hit type | damage << 8,
// u16 remaining, u16 maximum, and 0x80 on the kind for a break -- READ); the
// layout here is OURS.
type WallInfo struct {
	Absorbed   bool
	Broke      bool
	Critical   bool
	ToggledOff bool
	Damage     int32
	HP         int32
	Max        int32
}

// The WallInfo flag bits.
const (
	WallAbsorbed   uint8 = 0x01
	WallBroke      uint8 = 0x02
	WallCritical   uint8 = 0x04
	WallToggledOff uint8 = 0x08
)

// wallInfoSize is WallInfo's length on the wire.
const wallInfoSize = 13

func (w WallInfo) flags() uint8 {
	var f uint8
	if w.Absorbed {
		f |= WallAbsorbed
	}
	if w.Broke {
		f |= WallBroke
	}
	if w.Critical {
		f |= WallCritical
	}
	if w.ToggledOff {
		f |= WallToggledOff
	}
	return f
}

func (w WallInfo) encode() []byte {
	out := []byte{w.flags()}
	out = appendInt32(out, w.Damage)
	out = appendInt32(out, w.HP)
	return appendInt32(out, w.Max)
}

func decodeWallInfo(b []byte) (WallInfo, bool) {
	if len(b) < wallInfoSize {
		return WallInfo{}, false
	}
	f := b[0]
	return WallInfo{
		Absorbed: f&WallAbsorbed != 0, Broke: f&WallBroke != 0, Critical: f&WallCritical != 0, ToggledOff: f&WallToggledOff != 0,
		Damage: readInt32(b[1:]), HP: readInt32(b[5:]), Max: readInt32(b[9:]),
	}, true
}

func appendInt32(out []byte, v int32) []byte {
	u := uint32(v)
	return append(out, byte(u), byte(u>>8), byte(u>>16), byte(u>>24))
}

func readInt32(b []byte) int32 {
	return int32(uint32(b[0]) | uint32(b[1])<<8 | uint32(b[2])<<16 | uint32(b[3])<<24)
}

// RunToggleTicker is the rest of SkillAction_Buff's sub-state 2 for the
// toggles (READ, 0x5830b0): every poll, each owner with a drain due takes
// onff[1] MP for each due record -- or, short of it, loses the record -- and
// each owner with a broken wall loses it. It polls every buffPoll (OURS, as
// the buff ticker does); the tests themselves are exact.
func RunToggleTicker(ctx context.Context, hub *world.Hub, chars character.Store, deps RegenDeps, logger *slog.Logger) {
	t := time.NewTicker(buffPoll)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-t.C:
			togglePass(ctx, hub, chars, deps, now)
		}
	}
}

// togglePass is one pass of RunToggleTicker at now.
func togglePass(ctx context.Context, hub *world.Hub, chars character.Store, deps RegenDeps, now time.Time) {
	for _, owner := range buffBooks.DueToggles(now) {
		// A wall broken in the last BrokenGrace is left to the strike that
		// broke it, which ends it after the blow's messages (review).
		endBrokenWallBy(hub, owner, now.Add(-buff.BrokenGrace))
		drainOwner(ctx, hub, chars, deps, owner, now)
	}
}

// drainOwner takes ownerID's due toggle drains at now (READ, sub-state 2,
// 0x585253..0x5852ee): `if (MP < onff[1]) end (0x585284, signed jl); else {
// MP -= cost (vslot 0x308(0, cost, 4)); stamp now }` -- a pool equal to the
// cost pays it and stays at 0. Between the test and the take, a row with
// 'BDMD' (+0x554) scales the cost by (1 - v/100) with v from the entry
// FUN_005a0330 finds in the caster's book map (0x58528a..0x5852cb); OpenSRO
// keeps no such entries (the passives that file them are not modelled), so
// the cost is onff[1] (OPEN). The owner's bar is pushed afterwards, as regen
// pushes it.
func drainOwner(ctx context.Context, hub *world.Hub, chars character.Store, deps RegenDeps, ownerID int64, now time.Time) {
	if deps.Mana == nil || chars == nil {
		return
	}
	if len(buffBooks.DueDrains(ownerID, now)) == 0 {
		return
	}
	// The row read first, outside the owner's buff lock (a store read); the
	// due records are then read again under the lock, so a toggle a cancel,
	// a recast or a break ended in between is not charged (round 640's
	// review).
	c, err := chars.GetByID(ctx, ownerID)
	if err != nil || c == nil {
		return
	}
	maxMP := c.MaxMP()
	drained := false
	l := buffLock(ownerID)
	l.Lock()
	for _, r := range buffBooks.DueDrains(ownerID, now) {
		if left, ok := deps.Mana.Spend(ownerID, maxMP, r.OnffMP); ok {
			buffBooks.Drained(ownerID, r.Token, now)
			drained = true
			slog.Info("toggle: drain", "character", ownerID, "skill", r.SkillID, "mp", r.OnffMP, "left", left)
			continue
		}
		slog.Info("toggle: MP short of the drain, ended", "character", ownerID, "skill", r.SkillID, "mp", r.OnffMP,
			"have", deps.Mana.Current(ownerID, maxMP))
		ended, sp := buffBooks.EndToken(ownerID, r.Token)
		if len(ended) > 0 {
			broadcastBuffEnd(zoneOf(hub, ownerID), ownerID, ended, sp)
		}
	}
	l.Unlock()
	if !drained || hub == nil {
		return
	}
	e, ok := hub.EntityByCharacterID(ownerID)
	if !ok || e.Session == nil {
		return
	}
	result, err := buildCharacterStats(ctx, c, c.ID, deps.Equipment, deps.Items, deps.Skills, deps.Mana)
	if err != nil {
		return
	}
	_ = e.Session.Send(&proto.Packet{Opcode: OpCharacterStatsResult, Data: result.Encode()})
}
