package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"log/slog"
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
// it as no target. It comes back through OpRevive -- in place, at
// character.RespawnFraction of each maximum -- or, for a session that never
// sends one (a client older than round 548), through the auto-revive fallback
// after AutoReviveAfter. With the flag off nothing changes: the kill respawns
// at once and the wire is byte for byte what it was.
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
//     GetParam(4) x 0.4, 8), the 0.4 being `fmul QWORD ds:0xb460f0` at
//     0x5100fa / 0x51019e -- the double character.RespawnFraction cites; (c)
//     option 1 -> Revive(0), the return-point path, and GameEventLog 0x15/2.
//   - GObjPC::Revive (0x4df290): with 1 it passes 1 through SetLifeState
//     (+0x1f0), then +0x55c, SetBodyMode (+0x318) and ApplyHPMPDelta(this, 1,
//     0, 8) -- one HP, the pools being the caller's; with 0 it does NOT set
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
//     no `_CHAR.AppointedTeleport`, no teleport gates and no region frame to
//     put a LatestRegion/Pos into (world.Position is a zone label and a
//     point). So a character of level 11 or more revives where it fell, a
//     stand-in; one of 10 or under revives as retail's option 2 does.
//     srrevamp's Level stands in for GetMaxLevel, which it equals here: a
//     death never costs a level (GObjPC_OnDeath leaves CurLevel alone) and
//     nothing else lowers one.
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
// and the keep-up cancelled. HP stays where ApplyDamage left it, 0. A
// character already dead (a second monster's swing racing the first's) is
// left as it is: the compare-and-swap fails and the earlier time of death
// stands.
func markDead(deps strikeDeps, characterID int64, now time.Time) {
	deps.hub.SetLifeState(characterID, world.LifeAlive, world.LifeDead, now)
	if deps.potions != nil {
		deps.potions.drop(characterID)
	}
	keepUp.Cancel(characterID)
}

// revivePlayer brings characterID back where it lies: HP to
// character.RespawnFraction of the maximum (chars.RespawnHP), MP the same
// (character.RespawnMP through the tracker), then life state 1 -- the order
// GObjPC_HandleResurrectMsg_053 takes is Revive(1) then ApplyHPMPDelta, and
// the two writes are independent, so the pools go first here and the state's
// compare-and-swap last: a revive that loses the race to another (the handler
// against the fallback) has restored the same pools twice, harmlessly, and
// answers errNotDead so only one OpReviveResult goes out. It returns the
// character as it stands and its MP.
func revivePlayer(ctx context.Context, chars character.Store, mp *mana.Tracker, hub *world.Hub, characterID int64) (*character.Character, int, error) {
	if !deadCharacter(hub, characterID) {
		return nil, 0, errNotDead
	}
	if err := chars.RespawnHP(ctx, characterID); err != nil {
		return nil, 0, fmt.Errorf("session: reviving %d: %w", characterID, err)
	}
	c, err := chars.GetByID(ctx, characterID)
	if err != nil {
		return nil, 0, fmt.Errorf("session: reviving %d: %w", characterID, err)
	}
	mpNow := 0
	if mp != nil {
		mpNow = character.RespawnMP(c.MaxMP())
		mp.Refill(characterID, mpNow)
	}
	if !hub.SetLifeState(characterID, world.LifeDead, world.LifeAlive, time.Time{}) {
		return nil, 0, errNotDead
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

// autoReviveTick is one pass at now. Split out so a test can drive it with
// its own clock.
func autoReviveTick(ctx context.Context, hub *world.Hub, chars character.Store, deps RegenDeps, now time.Time, logger *slog.Logger) {
	if hub == nil || chars == nil {
		return
	}
	for _, e := range hub.AllEntities() {
		if e.Life != world.LifeDead || e.DiedAt.IsZero() || now.Sub(e.DiedAt) < AutoReviveAfter {
			continue
		}
		c, mpNow, err := revivePlayer(ctx, chars, deps.Mana, hub, e.CharacterID)
		if errors.Is(err, errNotDead) {
			continue // revived on request between the listing and now
		}
		if err != nil {
			if logger != nil {
				logger.Warn("auto-revive failed", "character", e.CharacterID, "err", err)
			}
			continue
		}
		if logger != nil {
			logger.Info("auto-revive", "character", e.CharacterID, "after", now.Sub(e.DiedAt), "hp", c.HP)
		}
		_ = sendRevived(ctx, e.Session, c, mpNow, deps)
	}
}
