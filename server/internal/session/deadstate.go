package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/mana"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// The player's dead state, the server half (round 549; the client half is
// round 548, docs/protocol/monster_ai.md "The player's dead state: the client
// half"). Until this round a monster's killing blow put the player back on
// its feet in the same call (monsterStrike's RespawnHP), so no player was ever
// dead on the wire. Behind cmd/server's -player-dead-state
// (SRREVAMP_PLAYER_DEAD_STATE), OFF by default, a monster's kill now leaves the
// character in life state 2 (world.LifeDead) at HP 0, with its potion queue
// emptied and its keep-up cancelled; while dead its moves are neither stored
// nor relayed and its attacks, casts, items, pick-ups, duel blows, trade
// requests, zone changes and GM teleports are refused; the monster AI treats
// it as no target. It comes back through OpRevive -- in place, HP at
// 1 + trunc(0.4 x MaxHP) as the retail handler's arithmetic lands it
// (reviveHPDelta, round 550), MP at character.RespawnMP -- or, for a session
// that never sends one (a client older than round 548), through the
// auto-revive fallback after AutoReviveAfter. With the flag off nothing
// changes ON A KILL: it respawns at once and the kill's wire is what it was;
// the one flag-independent piece is the entry revive of a stored HP 0
// (handleEnterWorld, the last stand-in below).
//
// GROUNDING, re-read on the RE box for this round (2026-09-24):
//
//   - Life state 1 ALIVE / 2 DEAD: world.LifeAlive / world.LifeDead, from
//     docs/protocol/character_state.md rounds 411-413 (the typed receiver).
//   - The retail resurrect request, GObjPC_HandleResurrectMsg_053 (0x50fee0):
//     one u8 option; acts only in life state 2 (`cmp al,0x2` at 0x510077);
//     refuses during a siege countdown above 0xa5; then (a) death cause
//     [this+0x1cb4] == 2 (leveldata.DeathCauseNoPenalty -- not a monster's
//     kill, which is 3) or (b) option 2 with IGObj::GetMaxLevel (+0x128) at
//     most 10 (`cmp al,0xa; ja` at 0x51017f) -> GObjPC::Revive(1) (`push 0x1;
//     call 0x4df290` at 0x5100e3) and ApplyHPMPDelta(GetParam(3) x 0.4,
//     GetParam(4) x 0.4, 8) (`call 0x4a86a0` at 0x51015d), the 0.4 being
//     `fmul QWORD ds:0xb460f0` at 0x5100fa / 0x51019e -- 0xb460f0 reads
//     `00 00 00 a0 99 99 d9 3f` = 0x3FD99999A0000000 = 0.4000000059604645,
//     the FLOAT 0.4 widened to a double (round 550's correction of "the
//     double 0.4"; character.RespawnFraction says why the exact 0.4 gives
//     the same integer) -- and each product TRUNCATED: `fnstcw; or eax,0xc00;
//     fldcw; fistp` sets rounding control 11, toward zero -- on path (a) at
//     0x510102..0x510122 (HP) and 0x510136..0x51014e (MP); path (b) has its
//     own identical pair, 0x5101a6 fnstcw / 0x5101af or eax,0xc00 / 0x5101be
//     fldcw / 0x5101c6 fistp (HP), then the MP `fmul` at 0x5101d4 and its
//     fnstcw at 0x5101da (round 551 named the paths; round 550 cited only
//     (a)'s); (c) option 1 -> Revive(0), the return-point path, and
//     GameEventLog 0x15/2.
//   - GObjPC::ApplyHPMPDelta (0x4a86a0) is ADDITIVE (round 550): it hands
//     both deltas to GObjPC::FUN_004a87d0 -- each non-zero one first scaled
//     by 1 - param/100, param 143 for HP (`mov eax,0x8f` at 0x4a86bb, `fdiv
//     QWORD ds:0xb45af0` = 100.0 at 0x4a86c9, `fld1; fsubrp; fimul`) and 144
//     for MP (0x4a8706, 0x4a8714), the panic and combustion percentages of
//     round 491, zero while neither state is on and not modelled -- which
//     itself scales nothing: it reads GetHP (+0x108) and
//     ADDS the delta (`add edi,ebx` at 0x4a8821) before SetHP
//     (GObjChar::FUN_004a66f0: at or above GetMaxHP (+0x110) the maximum,
//     below 0 zero), and the same for MP through +0x10c / +0x114 /
//     FUN_004a6790. So option 2 lands at HP = min(MaxHP, 1 + trunc(0.4 x
//     MaxHP)) -- the 1 from Revive(1) below -- and MP = min(MaxMP, MP at
//     death + trunc(0.4 x MaxMP)), the death path not being seen to write
//     MP (one probe: the decompiles of GObjPC_OnDeath 0x4e6980 and
//     FUN_004e67b0 name neither MP slot, +0x10c / +0x114, nor FUN_004a6790
//     nor either ApplyHPMPDelta; a write by another route is not excluded).
//   - GObjPC::Revive (0x4df290): with 1 it passes 1 through SetLifeState
//     (+0x1f0) FIRST, then +0x55c, SetBodyMode (+0x318) and ApplyHPMPDelta(this,
//     1, 0, 8) -- one HP, the pools being the caller's; with 0 it does NOT set
//     the life state there and asks CGObjPC::FUN_004e08a0 for the RETURN
//     POINT, which this round read: the character's `_CHAR.AppointedTeleport`
//     (+0xa4, the designated teleport gate, its position through
//     FUN_004e0a40) and, for an unknown gate ("someone designated unknown
//     teleport gate: %d") or a siege world, `_CHAR.LatestRegion / PosX / PosY
//     / PosZ / WorldID` (+0x94, +0x98, +0x9c, +0xa0, +0xec;
//     docs/protocol/db_bind_offsets.tsv), then slot 0x378 with it.
//   - AITactics_IsValidTarget (0x540de0, round 424) returns no target unless
//     GetLifeState() == 1 (the `(+0xf8)() != 1` test before its body-mode
//     tests): a dead player is no AI target.
//   - Death empties both potion lists: GObjPC::FUN_004e67b0 (0x4e67b7 ->
//     FUN_0049a4c0), and ApplyHPMPDelta lands nothing unless GetLifeState is
//     1 (`cmp al,0x1` at 0x4a87e8 after the +0xf8 call at 0x4a87e6).
//   - A dead player may not use an item: Item_HandleUseItem (0x510980) asks
//     GetLifeState (0x510c9c; `cmp al,0x1` at 0x510ca6) and answers 0x1889
//     (0x510cd0) unless the state is 1 -- or 2 for one exempt TID class
//     (`(tid & 0xf800) == 0x3000` under FUN_004929c0, `cmp al,0x2` at
//     0x510cb6), which srrevamp does not model.
//   - A dead player may not ask for a trade: GObjPC_HandleTradeMsg_081
//     (0x5154e0) asks the REQUESTER's GetLifeState (0x515607; `cmp al,0x1` at
//     0x515611) and answers 0x181d otherwise.
//
// STAND-INS, each disclosed at its line and in the round's section:
//
//   - Reviving IN PLACE at any level. The retail handler revives in place
//     (option 2) only while GetMaxLevel is at most 10; above that the client
//     offers the return point (option 1), which srrevamp cannot build: it has
//     no `_CHAR.AppointedTeleport` and no teleport gates. (The last-resort
//     LatestRegion/Pos is kept on the row since round 573, under
//     -persist-position -- but it is where the character already stands, so
//     it builds no return point either.) So a character of level 11 or
//     more revives where it fell, a stand-in; one of 10 or under revives as
//     retail's option 2 does. No level test is made: both take the one
//     in-place path, and GetMaxLevel is not modelled (srrevamp's Level
//     would equal it -- a death never costs a level, GObjPC_OnDeath leaves
//     CurLevel alone -- but nothing here reads it).
//   - The revived MP. Retail ADDS trunc(0.4 x MaxMP) to the MP the character
//     died with (ApplyHPMPDelta above); srrevamp SETS the tracker to
//     character.RespawnMP, a stand-in. (Corrected round 607: this used to
//     say mana.Tracker regenerates by wall clock while dead. It regenerates
//     nothing now, and the regen tick's first test is the life state --
//     read, 0x4e29a9 -- so the MP she died with is intact; SET for ADD is
//     the whole difference.) The HP is exact: a dead character's HP is 0
//     (potions land nothing, and the regen tick skips the dead), and
//     reviveHPDelta adds the handler's sum through Store.Heal, the same
//     add-and-clamp.
//   - The flag-off instant respawn (monsterStrike's RespawnHP) keeps the
//     load path's trunc(0.4 x MaxHP), not the handler's +1: that wire is
//     what an older client's tests pin, and the compression of a death and
//     a revive into one call is the stand-in there, not the number.
//   - The empty request. Round 548's client sends OpRevive with no payload;
//     retail's 0x7053 carries the u8 option. An empty request is option-2
//     semantics by that round's contract, and any payload is ignored here so
//     an option byte can be added later without breaking either side.
//   - The auto-revive fallback and its 30 s (AutoReviveAfter). The engine's
//     nearest thing is the siege countdown (CGObjPC::PeriodicUpdateInSiege ->
//     GObjPC::Revive), a per-second countdown whose start value is unread and
//     which runs only during a fortress war. Own design, so an older client
//     -- no button, no OpRevive -- is never stuck dead.
//   - The refusal strings (deadRefusal, "not dead") and the pick-up, duel,
//     zone-change and GM-teleport refusals, whose retail handlers were not
//     read for a life-state test (the pick-up handler 0x034 is a vtable
//     thunk; the duel and zone messages were not opened).
//   - Revive on entry (handleEnterWorld): a character logged out dead enters
//     at RespawnFraction. The FRACTION is the load path's own rule
//     (character.RespawnFraction: GObjPC::FUN_004e1120 restores a stored
//     zero pool to 40 %), applied whatever the flag says -- a character dead
//     when the flag is turned off must not enter alive at 0 HP; doing it at
//     entry rather than keeping the character dead across sessions is the
//     stand-in.

// playerDeadState is cmd/server's -player-dead-state, OFF by default. An
// atomic because cmd/server sets it on the boot goroutine and the strike
// reads it on session readers, keep-up goroutines and the AI's strike workers.
var playerDeadState atomic.Bool

// SetPlayerDeadState turns the player's dead state on or off. cmd/server
// calls it once at boot, before the gateway serves. Only ENTERING the state
// is gated: everything else follows the state itself, so a character can
// only be dead while the flag is on.
func SetPlayerDeadState(on bool) { playerDeadState.Store(on) }

// The revive pair, placeholders in the world group like every opcode here
// (docs/protocol/PROTOCOL_DECISION.md). 0x0028/0x0029 were free before round
// 548 (grep, 2026-09-24) and the client half pins them
// (client/scripts/net/world.gd OP_REVIVE / OP_REVIVE_RESULT).
const (
	OpRevive       uint16 = 0x0028 // client -> server, empty: revive me where I lie
	OpReviveResult uint16 = 0x0029 // server -> the requester (or unasked, from the fallback)
)

// AutoReviveAfter is how long a dead character waits before the server
// revives it unasked (RunAutoRevive). OWN DESIGN and a user decision, the
// plan's disclosed 30 s: it exists so a client without round 548's Revive
// button is never stuck dead. Retail has no such fallback outside a fortress
// war's countdown (character_state.md, "The siege revive").
const AutoReviveAfter = 30 * time.Second

// autoReviveTickInterval is how often RunAutoRevive looks. OWN DESIGN; the
// siege countdown is decremented on the PC's one-second tick, so the
// fallback is honoured to within a second.
const autoReviveTickInterval = time.Second

// deadRefusal is the error string a request refused for being dead carries.
// srrevamp's own wording; the engine answers a code (0x1889 for an item,
// 0x181d for a trade request, GUILDERR_IM_DEAD for guild work).
const deadRefusal = "you are dead"

// errNotDead is revivePlayer's answer for a character that is not in life
// state 2 -- the retail handler's `cmp al,0x2` (0x510077), which does nothing
// for a living character.
var errNotDead = errors.New("not dead")

// ReviveResult is the OpReviveResult payload: a u16-prefixed error string,
// empty on success, then s32 HP and s32 MP -- the pools the character came
// back with (client/scripts/net/world.gd decode_revive_result). A refusal
// carries no tail; the client's decoder takes it either way.
type ReviveResult struct {
	Error string
	HP    int32
	MP    int32
}

func (r *ReviveResult) Encode() []byte {
	out := encodeStrings(r.Error)
	if r.Error != "" {
		return out
	}
	tail := make([]byte, 8)
	binary.LittleEndian.PutUint32(tail[0:4], uint32(r.HP))
	binary.LittleEndian.PutUint32(tail[4:8], uint32(r.MP))
	return append(out, tail...)
}

// DecodeReviveResult mirrors the client's decoder: a refusal with or without
// its tail, a success needing all eight bytes. Only tests call it -- the
// message goes server to client.
func DecodeReviveResult(data []byte) (*ReviveResult, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding ReviveResult: %w", err)
	}
	r := &ReviveResult{Error: fields[0]}
	if r.Error != "" {
		return r, nil
	}
	if len(rest) < 8 {
		return nil, errors.New("session: decoding ReviveResult: truncated vitals")
	}
	r.HP = int32(binary.LittleEndian.Uint32(rest[0:4]))
	r.MP = int32(binary.LittleEndian.Uint32(rest[4:8]))
	return r, nil
}

// deadBySession reports whether the character on sess is in the world and
// dead: the "must be alive" test every refusing handler makes, on the O(1)
// session index.
func deadBySession(hub *world.Hub, sess *gateway.Session) bool {
	if hub == nil || sess == nil {
		return false
	}
	e, ok := hub.EntityBySession(sess.ID())
	return ok && e.Life == world.LifeDead
}

// deadCharacter reports whether characterID is in the world and dead, for a
// caller that holds only the character (a swing's target, a duel's opponent).
func deadCharacter(hub *world.Hub, characterID int64) bool {
	if hub == nil {
		return false
	}
	e, ok := hub.EntityByCharacterID(characterID)
	return ok && e.Life == world.LifeDead
}

// markDead is what a monster's killing blow does to characterID under
// -player-dead-state, once the experience penalty is applied (monsterStrike):
// life state 2 with the time of death (world.Hub.SetLifeState), the potion
// queue emptied -- GObjPC::FUN_004e67b0's FUN_0049a4c0 empties both lists, and
// ApplyHPMPDelta would land nothing on a dead character anyway (0x4a87e8) --
// and the keep-up cancelled. HP stays where ApplyDamage left it, 0. It reports
// whether the compare-and-swap made the change. Which of two racing kills
// gets here is decided one step earlier, under the character's kill lock
// (killLock, round 551; the caller holds it): monsterStrike reads her back
// under the lock and only the blow that finds her alive at 0 comes here, so
// the second blow never charges the penalty and the swap cannot fail against
// another kill or a revive (revivePlayer takes the same lock). Round 550 had
// the store's transition flag decide instead, which left a character alive at
// 0 unkillable; before that both blows read died=true and both charged
// leveldata.DeathPenaltyExp before the second's compare-and-swap failed here.
func markDead(deps strikeDeps, characterID int64, now time.Time) bool {
	changed := deps.hub.SetLifeState(characterID, world.LifeAlive, world.LifeDead, now)
	if deps.potions != nil {
		deps.potions.drop(characterID)
	}
	keepUp.Cancel(characterID)
	return changed
}

// reviveHPDelta is what GObjPC_HandleResurrectMsg_053's option-2 path ADDS to
// a dead character's HP, which is 0 (round 550): GObjPC::Revive(1)'s
// ApplyHPMPDelta(this, 1, 0, 8) -- one HP -- and then the handler's own
// ApplyHPMPDelta(trunc(GetParam(3) x 0.4), trunc(GetParam(4) x 0.4), 8) (`call
// 0x4a86a0` at 0x51015d). Both go through GObjPC::FUN_004a87d0, which adds the
// delta to GetHP (`add edi,ebx` at 0x4a8821) and clamps through SetHP
// (GObjChar::FUN_004a66f0: GetMaxHP at or above it), and the handler
// truncates (rounding control 11: 0x510102..0x510122 on the death-cause-2
// path, 0x5101a6..0x5101c6 on option 2's -- the header). So retail lands at
// min(MaxHP, 1 + trunc(0.4 x MaxHP)); Store.Heal is the same add-and-clamp.
// The truncation is int()'s, and character.RespawnFraction's comment says why
// the exact 0.4 gives the widened float's integer.
func reviveHPDelta(maxHP int) int {
	return 1 + int(float64(maxHP)*character.RespawnFraction)
}

// revivePlayer brings characterID back where it lies, in the order
// GObjPC_HandleResurrectMsg_053 takes: Revive(1) passes 1 through SetLifeState
// FIRST, and the pools come after (Revive's own ApplyHPMPDelta(this, 1, 0, 8),
// then the handler's). So the compare-and-swap 2 -> 1 goes first here: of two
// revives racing each other (the handler against the fallback) exactly one
// wins it and touches the pools; the loser answers errNotDead at once, and
// one OpReviveResult goes out. Until round 550 the pools went first and the
// state last, which left a window in which a blow found HP above 0 in life
// state 2: its kill's compare-and-swap 1 -> 2 failed, and the revive then set
// state 1 on a pool the blow had just emptied -- a character alive at 0 HP.
// State first, and since round 551 the whole of it -- the swap and the pools
// -- under the character's kill lock (killLock): a blow that leaves her at 0
// reads her back under that lock, so it sees either life state 2 (before
// the swap: dropped) or the revived pool (after: it lands as usual), never
// "alive at 0" between the two, which the round-551 arbiter would take for
// a kill. Then the HP: reviveHPDelta through Store.Heal (the handler's
// additive arithmetic, clamped at the maximum), and the MP tracker to
// character.RespawnMP (the disclosed stand-in in the header). A store
// failure after the state changed puts the state back with its time of
// death, so the character is dead again for the next attempt rather than
// alive at 0. It returns the character as it stands and its MP.
func revivePlayer(ctx context.Context, chars character.Store, mp *mana.Tracker, hub *world.Hub, characterID int64) (*character.Character, int, error) {
	if hub == nil {
		return nil, 0, errNotDead
	}
	e, ok := hub.EntityByCharacterID(characterID)
	if !ok || e.Life != world.LifeDead {
		return nil, 0, errNotDead
	}
	l := killLock(characterID)
	l.Lock()
	defer l.Unlock()
	if !hub.SetLifeState(characterID, world.LifeDead, world.LifeAlive, time.Time{}) {
		return nil, 0, errNotDead
	}
	stillDead := func(err error) (*character.Character, int, error) {
		hub.SetLifeState(characterID, world.LifeAlive, world.LifeDead, e.DiedAt)
		return nil, 0, fmt.Errorf("session: reviving %d: %w", characterID, err)
	}
	c, err := chars.GetByID(ctx, characterID)
	if err != nil {
		return stillDead(err)
	}
	hp, err := chars.Heal(ctx, characterID, reviveHPDelta(c.MaxHP()), c.MaxHP())
	if err != nil {
		return stillDead(err)
	}
	c.HP = hp
	// GObjPC::Revive stands the character (SetMotionState(STAND) at
	// 0x4df427; round 607, motion.go).
	motions.stand(characterID, time.Now())
	mpNow := 0
	if mp != nil {
		mpNow = character.RespawnMP(c.MaxMP())
		mp.Refill(characterID, mpNow)
	}
	return c, mpNow, nil
}

// sendRevived tells sess it is back: the OpReviveResult with the pools, then
// the stats push the HUD's MP bar moves on (the result carries MP, but round
// 548's client paints only HP from it and asks for its stats after; the push
// spares it the round trip, as regen's does). The push is best effort.
func sendRevived(ctx context.Context, sess *gateway.Session, c *character.Character, mpNow int, deps RegenDeps) error {
	if sess == nil {
		return nil
	}
	res := &ReviveResult{HP: int32(c.HP), MP: int32(mpNow)}
	if err := sess.Send(&proto.Packet{Opcode: OpReviveResult, Data: res.Encode()}); err != nil {
		return err
	}
	if stats, err := buildCharacterStats(ctx, c, c.ID, deps.Equipment, deps.Items, deps.Skills, deps.Mana); err == nil {
		_ = sess.Send(&proto.Packet{Opcode: OpCharacterStatsResult, Data: stats.Encode()})
	}
	return nil
}

// ReviveHandler returns a gateway.Handler implementing OpRevive: the session's
// own in-world character, dead, is revived where it lies (revivePlayer) and
// answered with an OpReviveResult; a living one is answered "not dead", as the
// retail handler's `cmp al,0x2` does nothing for it. The request's payload is
// not read (the stand-in note above). deps build the stats push.
func ReviveHandler(chars character.Store, hub *world.Hub, deps RegenDeps) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpRevive {
			return nil
		}
		refuse := func(reason string) error {
			return sess.Send(&proto.Packet{Opcode: OpReviveResult, Data: (&ReviveResult{Error: reason}).Encode()})
		}
		e, ok := hub.EntityBySession(sess.ID())
		if !ok {
			return refuse("not in the world")
		}
		c, mpNow, err := revivePlayer(ctx, chars, deps.Mana, hub, e.CharacterID)
		if errors.Is(err, errNotDead) {
			return refuse("not dead")
		}
		if err != nil {
			return refuse("revive failed")
		}
		return sendRevived(ctx, sess, c, mpNow, deps)
	}
}

// RunAutoRevive is the fallback for a session that never sends OpRevive: every
// autoReviveTickInterval it revives, unasked, every character dead for
// AutoReviveAfter or longer and sends it the same OpReviveResult the handler
// would, which round 548's client takes the same way and an older client
// never needed (it never saw itself dead: its HP is simply back). cmd/server
// runs it only with -player-dead-state on; with the flag off nobody is ever
// dead and it would find nothing.
func RunAutoRevive(ctx context.Context, hub *world.Hub, chars character.Store, deps RegenDeps, logger *slog.Logger) {
	ticker := time.NewTicker(autoReviveTickInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-ticker.C:
			autoReviveTick(ctx, hub, chars, deps, now, logger)
		}
	}
}

// autoReviveWarned holds the characters whose auto-revive has failed and been
// logged, so a store that keeps failing is logged ONCE per character rather
// than every pass (round 550). An entry lives exactly as long as the failures
// do: a pass keeps only the characters whose revive FAILED on it and prunes
// every other entry, so the entry goes on the very pass that revives her,
// finds her revived on request, or no longer lists her. (The first cut kept
// every DUE character, the one it had just revived included, so her entry
// outlived the revive by a pass -- and, this being package state, reached the
// next test's fresh store with the same id and suppressed its WARN; the
// batch-18 review caught it as the test failing on -count=3.)
var autoReviveWarned sync.Map

// autoReviveTick is one pass at now. Split out so a test can drive it with
// its own clock.
func autoReviveTick(ctx context.Context, hub *world.Hub, chars character.Store, deps RegenDeps, now time.Time, logger *slog.Logger) {
	if hub == nil || chars == nil {
		return
	}
	failing := map[int64]bool{}
	for _, e := range hub.AllEntities() {
		if e.Life != world.LifeDead || e.DiedAt.IsZero() || now.Sub(e.DiedAt) < AutoReviveAfter {
			continue
		}
		c, mpNow, err := revivePlayer(ctx, chars, deps.Mana, hub, e.CharacterID)
		if errors.Is(err, errNotDead) {
			continue // revived on request between the listing and now
		}
		if err != nil {
			failing[e.CharacterID] = true
			if _, warned := autoReviveWarned.LoadOrStore(e.CharacterID, struct{}{}); !warned && logger != nil {
				logger.Warn("auto-revive failed", "character", e.CharacterID, "err", err)
			}
			continue
		}
		if logger != nil {
			logger.Info("auto-revive", "character", e.CharacterID, "after", now.Sub(e.DiedAt), "hp", c.HP)
		}
		_ = sendRevived(ctx, e.Session, c, mpNow, deps)
	}
	autoReviveWarned.Range(func(k, _ any) bool {
		if id, ok := k.(int64); !ok || !failing[id] {
			autoReviveWarned.Delete(k)
		}
		return true
	})
}
