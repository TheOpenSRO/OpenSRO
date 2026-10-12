package session

// The return scroll and the reverse return scroll (round 778;
// docs/protocol/reverse_return_scroll.md has every address and the client's
// half).
//
// READ (SR_GameServer, CGItemExpendable::vslot_307 0x49b9f0 -- DoJob's
// TypeID3 3 branch, `switch (TID >> 0xb)`):
//
//   - TypeID4 1, the return scroll: FUN_004a0380(Param1, Param2, ...). After
//     its refusals it records where it was used as the character's recall
//     point (vtable slot 153, CGObjPC::SaveCurPosAsLastTelPosition, `call
//     [eax+0x264]` at 0x4a055d) and starts the scroll state with option 0
//     (FUN_004e0b50 at 0x4a059a), which on expiry warps to the return point
//     (AJStateChanger::vslot_002 case 0xb, option 0: GObjPC::Revive(0), the
//     return-point move).
//   - TypeID4 3, the reverse return scroll: FUN_004a00c0(Param1, Param2) with
//     the request stream in EAX. Its refusals, in order: the user's world
//     must allow it (FUN_005f85a0 on the world id, else 0x18f5), not be a
//     special world (FUN_005f6c90, else 0x187a), no quest may block the job
//     (vslot 0x244(0x20000), else 0x185f), no scroll may already be working
//     (vslot 0x120, the scroll state, else 0x185d), a murderer may not
//     (chardata +0xc == 2, 0x1875), nor one with a trade cart (vslot 0x2ec,
//     0x185e). Then the option byte (FUN_00404c80 at 0x4a01b4):
//       2  the recall point (FUN_004e0130: charData +0xcc..; 0 -> 0x1885),
//       3  the death point (FUN_004e01c0: +0xdc..; 0 -> 0x1886),
//       7  a u32 refoptionalteleport id follows (FUN_00404e50 at 0x4a01d7):
//          no record or a record with no region -> 2; the user's level
//          outside its range -> 0x18fd (FUN_004a1ed0),
//       any other -> 2.
//     The destination's world must take the user (vslot 0x54 of the world,
//     CDataDrivenGameWorld::vslot_021, which answers 0x18f5) and a fortress
//     world wants a job mode (0x18e9) outside a siege (0x18f2). Then the
//     scroll state starts with the option and, for 7, the record
//     (FUN_004e0b50 at 0x4a0351: the state value (Param2 == 0) + 1, sub-kind
//     3, the delay (float)Param1, the option), and the use answers 1.
//   - The state's job (AJStateChanger::vslot_002 case 0xb) resolves the
//     destination when it expires, not when the scroll is used: option 2 and
//     3 read the stored point again (FUN_004e0130 / FUN_004e01c0, abandoning
//     on 0), 7 copies the record's region and x/y/z words (FUN_004076f0) --
//     then vslot 0x378 warps there and the state returns to 0. A character
//     locked at expiry (chardata +4 == 1) waits another second.
//   - The item is spent when the use succeeds: DoJob decrements the count
//     after UseByKind answers 1 (LAB_0049af45), before the delay.
//   - The death point is recorded on the death path (GObjPC::FUN_004e0330
//     from CGObjPC vslot_306 0x529b10) when the world allows it.
//   - The reply's refusal codes go to the client's category 1
//     (Item_OnUseItemResult 0x87a7b0: FUN_00778190(1, code)), whose names
//     are READ through the dispatcher's jump table (error_codes.md; the
//     client's ErrorText.scroll_line).
//
// OURS, disclosed:
//
//   - (Round 779 settled what round 778 left OPEN, the delay's unit: it is
//     READ now, below -- Param1 / 1000 whole seconds.)
//   - OpenSRO has one game world and no PK, quest blocks, trade carts or
//     fortresses, so the world, murderer, quest, cart and fortress refusals
//     have nothing to refuse; a destination OpenSRO cannot place (another
//     world, a dungeon it does not serve) is refused with 0x18f5, the world
//     test's own code.
//   - A cast whose character died, left the world or came back on another
//     session meanwhile is dropped (the engine's job has no life test).
//   - The thief-den return scrolls (ITEM_ETC_SCROLL_RETURN_THIEFDEN_*):
//     FUN_004a0380 tells them by Param3's descriptor ("THIEFDEN" against
//     "RESURRECT", 0xaeb2a0 / 0xaeb294; any other answers 2) and lets only a
//     character in job state 2 (vslot 0x11c, chardata +0xf) use one, else
//     0x186a UIIT_MSG_STRGERR_ONLY_ROBBER_CAN_USE_THIS_ITEM (READ, 0x4a04e6).
//     OpenSRO has no job system, so every character is refused with that
//     code (round 779). The export carries no descriptor column, so the
//     row is told by its code name, which holds the same word (OURS).
//
// Round 779, the cast (docs/protocol/return_scroll_cast.md has the client's
// half and every address):
//
//   - The delay (READ). The server's item loader, RefObjItem::ExtractData
//     (0x6a3d50), divides Param1 of a 3/3/3/1 or 3/3/3/3 row whose first
//     descriptor is not "xxx" and holds no "cooltime" by 1000 -- an integer
//     division (`+0x2a0 = +0x2a0 / 1000`) -- so the job gets whole seconds,
//     and the PC's job manager counts them down in seconds (elapsed
//     GetTickCount ms / 1000.0, 0x406605). The client's own tooltip says the
//     same: "PARAM_RECALL_TIME %d PARAM_SECOND" with Param1 / 1000
//     (0x677796). So 30000 is 30 s, 15000 15 s, 5000 5 s, 1000 1 s.
//   - The stop (READ). Both FUN_004a0380 and FUN_004a00c0 call vtable slot
//     300 (0x4b0, GObjPC::FUN_004a9430) with its send argument 1 before the
//     state starts: a moving character's leg ends and 0xB023 goes to the
//     window, the user included.
//   - The state (READ). FUN_004e0b50 broadcasts 0x30bf {id, kind 0xb,
//     value} (GObjPC::BroadcastStateChange) as it sets chardata +0x10; the
//     value is (Param2 == 0) + 1 -- 1 for every RESURRECT row, 2 for the
//     thief-den rows -- and the end, or a cancel, broadcasts value 0
//     (FUN_004e0b50(0, 0xff, 0, 0)). The client's handler (0x8a80a0 case
//     0xb) removes its own casting bar on 0 and, when one was up, says
//     UIIT_MSG_TRANSITION_CANCEL_RESULT. A spawn record carries the state
//     too (field 26, slot 72).
//   - The cancel (READ). The client's bar button sends 0x705B with no body
//     (UI_SILKMALL::FUN_0081ee60 case 0); its handler GObjPC::FUN_00513ea0
//     answers 0xB05B {2, u16 6} when no scroll works, else drops job 0xb
//     (FUN_004066c0(0xb, 0xb)) and sets the state 0 -- no reply, the 0x30bf
//     is the answer. The scroll stays spent (it went at the use).
//   - Death cancels (READ). CGObjPC vslot_306 and vslot_307 (the deaths)
//     build a 0x705B and run that handler when the state is set (0x529be9,
//     0x52ce59).
//   - What the state refuses (READ, every caller of vslot 0x120): another
//     scroll (0x185d), an NPC teleport (GObjPC::HandleTeleportUse, 0x1c14
//     UIIT_MSG_INTERACTION_FAIL_TELESCROLL_ALREADY_WORKING, before the range
//     test), a walk-in teleport (vslot_309), a pet summon (CGItemExpendable
//     slot 307 TypeID4 2 and CGItemCOSSummoner::CheckCanUse, 0x1869), a
//     logout (FUN_0050eff0 answers 0x802; that the client's text for it is
//     UIIT_MSG_LOGOUT_ERR_CANT_LOGOUT_WHILE_TELEPORT_WORKING is INFERRED),
//     a guild summon, a thief's pick-up of a special
//     good (0x186e) and some quest scripts. NOT movement: the 0x7021
//     handler (0x4b0ea0) never asks; nor a skill or an attack (the 0x7074
//     handler and Skill_CheckUseConditions never ask, and the client's busy
//     flag, the delay board's +0x36c, is not set for a return scroll's bar).
//     So a character may walk on after the stop, and the cast still moves it
//     when it runs out. OpenSRO models the scroll, the NPC teleport and the
//     walk-in refusals; it has no pets, logout, guild summon or thieves.
import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/berserk"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/teleport"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
	"github.com/OpenSRO/OpenSRO/server/internal/worldmap"
)

// The scroll family: TypeID 3/3/3 (DoJob's case 3), and its two kinds.
const (
	scrollFamily        = 3
	returnScrollKind    = 1 // vslot_307 case 1 -> FUN_004a0380
	reverseReturnScroll = 3 // vslot_307 case 3 -> FUN_004a00c0
)

// The reverse return scroll's option byte (READ, FUN_004a00c0 0x4a01b9 and
// the client's message box kind 0x21: FUN_00797d90 0x798862..0x7988d8).
const (
	ReverseOptionRecall byte = 2 // "Move to the last recall point."
	ReverseOptionDeath  byte = 3 // "Move to the place where you died."
	ReverseOptionMap    byte = 7 // "Move to certain location at the map." + u32 id
)

// The refusal codes (READ; names from the client's category-1 table).
const (
	ScrollErrUnknownOption   uint16 = 2      // an option or a record the handler has no case for
	ScrollErrAlreadyWorking  uint16 = 0x185d // UIIT_MSG_STRGERR_PREV_TELESCROLL_ALREADY_WORKING
	ScrollErrNoRecallPoint   uint16 = 0x1885 // UIIT_MSG_STRGERR_CANT_FIND_LAST_TELEPOS
	ScrollErrNoDeathPoint    uint16 = 0x1886 // UIIT_MSG_STRGERR_CANT_FIND_LAST_DIEDPOS
	ScrollErrArea            uint16 = 0x18f5 // UIIT_MSG_ITEM_USE_REVERSE_PORTAL_RETRUN_TO_INS
	ScrollErrLevel           uint16 = 0x18fd // UIIT_MSG_INTERACTION_FAIL_OUT_OF_REQUIRED_LEVEL_FOR_TELEPORT
	ScrollErrWaitReuseDelay  uint16 = 0x185b // UIIT_MSG_STRGERR_WAIT_FOR_REUSE_DELAY
	scrollFallbackDelayMilli        = 100    // FUN_004e0b50's floor: a delay <= 1e-6 becomes 0.1 (0xb45eb8)
)

// isScroll reports whether it is a return scroll (kind 1) or a reverse return
// scroll (kind 3): TypeID 3/3/3/kind.
func isScroll(it *refdata.Item, kind int) bool {
	return it != nil && it.TypeID1 == equipment.TypeItem && it.TypeID2 == equipment.TypeExpendable &&
		it.TypeID3 == scrollFamily && it.TypeID4 == kind
}

// IsReverseReturnScroll reports whether it is a reverse return scroll, 3/3/3/3
// (the client's own test, FUN_0078e870: `(tid & 0xf800) == 0x1800` over
// 3/3/3).
func IsReverseReturnScroll(it *refdata.Item) bool { return isScroll(it, reverseReturnScroll) }

// IsReturnScroll reports whether it is an ordinary return scroll, 3/3/3/1.
func IsReturnScroll(it *refdata.Item) bool { return isScroll(it, returnScrollKind) }

// scrollDelay is the scroll state's delay: Param1 (itemdata column 118, the
// export's RestoreHP) / 1000 whole seconds -- RefObjItem::ExtractData's
// integer division, counted down in seconds by the PC's job manager (READ,
// the header) -- with FUN_004e0b50's floor: a delay <= 1e-6 (0xb45c84)
// becomes 0.1 s (0xb45eb8), so a Param1 under 1000 casts for 0.1 s.
func scrollDelay(it *refdata.Item) time.Duration {
	sec := it.RestoreHP / 1000
	if sec <= 0 {
		return scrollFallbackDelayMilli * time.Millisecond
	}
	return time.Duration(sec) * time.Second
}

// scrollStateValue is the value the scroll state is set to and broadcast
// with: (Param2 == 0) + 1 (READ, FUN_004a0380 0x4a0459 and FUN_004a00c0's
// own) -- 1 for every RESURRECT row, whose Param2 is 1, 2 for the thief-den
// rows (Param2 0). Param2 is itemdata column 120, the export's
// ReinforceRate1 on every row.
func scrollStateValue(it *refdata.Item) byte {
	if it.ReinforceRate1 == 0 {
		return 2
	}
	return 1
}

// The scroll state's wire (READ, the header): the 0x30bf kind, the cancel
// request and its refusal.
const (
	// StateKindTeleport is 0x30bf's kind for the scroll state: FUN_004e0b50
	// passes 0xb to GObjPC::BroadcastStateChange.
	StateKindTeleport byte = 0xb
	// OpScrollCancel is retail's 0x705B, sent with no body by the casting
	// bar's cancel button (UI_SILKMALL::FUN_0081ee60 case 0, logging
	// "Teleport Casting Cancel").
	OpScrollCancel uint16 = 0x705B
	// OpScrollCancelResult is retail's 0xB05B: GObjPC::FUN_00513ea0 sends it
	// only to refuse, {u8 2, u16 code}; the client's FUN_008727a0 reads the
	// code and shows nothing.
	OpScrollCancelResult uint16 = 0xB05B
	// ScrollCancelErrNotCasting is the refusal's code: no scroll works
	// (`push 0x6` at 0x513eba).
	ScrollCancelErrNotCasting uint16 = 6
	// ScrollErrOnlyRobber is the thief-den scroll's refusal for a character
	// not in job state 2: UIIT_MSG_STRGERR_ONLY_ROBBER_CAN_USE_THIS_ITEM
	// (0x4a04e6; the name through category 1's jump table, index 0x3f ->
	// 0x7b90c7).
	ScrollErrOnlyRobber uint16 = 0x186a
)

// activeScrolls is the server's ScrollCaster (the last NewScrollCaster), for
// the paths outside the use-item handler the scroll state reaches: the death
// that cancels it, the NPC teleport and the walk-in that it refuses. nil
// when there is none.
var activeScrolls atomic.Pointer[ScrollCaster]

// scrollCastingOn reports whether sess's character has a scroll working, by
// the session that cast it (so a test's rig or a character that came back on
// another session is never mistaken for it).
func scrollCastingOn(sess *gateway.Session) bool {
	s := activeScrolls.Load()
	if s == nil || sess == nil {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, c := range s.casting {
		if c.sess == sess {
			return true
		}
	}
	return false
}

// cancelScrollForDeath is the deaths' cancel (CGObjPC vslot_306 / vslot_307
// run the 0x705B handler when the state is set, READ): characterID's cast,
// if its session is the one in the world, ends with the state's 0.
func cancelScrollForDeath(hub *world.Hub, characterID int64) {
	s := activeScrolls.Load()
	if s == nil || hub == nil {
		return
	}
	e, ok := hub.EntityByCharacterID(characterID)
	if !ok {
		return
	}
	s.cancel(characterID, e.Session, "death")
}

// ScrollCaster runs the scrolls' state: who is casting, and the move each
// cast makes when its delay runs out. One per server (cmd/server); nil in
// UseItemHandler refuses both scrolls as before round 778.
type ScrollCaster struct {
	chars  character.Store
	eq     equipment.Store
	hub    *world.Hub
	zerk   *berserk.Tracker
	logger *slog.Logger
	// network is the teleport network the map option's points come from;
	// nil reads recallNetwork (cmd/server's -teleport-dir).
	network *teleport.Table
	// after schedules a cast's end; time.AfterFunc unless a test replaces it.
	after func(time.Duration, func())

	mu      sync.Mutex
	casting map[int64]*scrollCast
}

// scrollCast is one running scroll state.
type scrollCast struct {
	sess   *gateway.Session
	option byte // 0 the return scroll, else the reverse scroll's option
	point  teleport.OptionalPoint
	// value is the state's value, (Param2 == 0) + 1 (round 779).
	value byte
}

// NewScrollCaster builds the casts' state and makes it the server's
// (activeScrolls). logger may be nil.
func NewScrollCaster(chars character.Store, eq equipment.Store, hub *world.Hub, zerk *berserk.Tracker, logger *slog.Logger) *ScrollCaster {
	s := &ScrollCaster{chars: chars, eq: eq, hub: hub, zerk: zerk, logger: logger,
		after:   func(d time.Duration, f func()) { time.AfterFunc(d, f) },
		casting: map[int64]*scrollCast{}}
	activeScrolls.Store(s)
	return s
}

// broadcastScrollState sends 0x30bf {id, kind 0xb, value} about characterID
// to the players in view that hold it, the character included --
// FUN_004e0b50's GObjPC::BroadcastStateChange (READ, the header). A
// character not in the hub hears nothing.
func broadcastScrollState(hub *world.Hub, characterID int64, value byte) {
	if hub == nil {
		return
	}
	msg := (&StateChange{ObjectID: uint32(characterID), Kind: StateKindTeleport, Value: value}).Encode()
	bumpPlayerState(characterID)
	sendAboutPlayerPacket(hub, characterID, true, OpStateChange, msg)
}

// scrollStateOf is the scroll state's value for characterID's spawn record
// (pcspawn field 26, slot 72): its cast's value, else 0.
func scrollStateOf(characterID int64) byte {
	s := activeScrolls.Load()
	if s == nil {
		return 0
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if c := s.casting[characterID]; c != nil {
		return c.value
	}
	return 0
}

// cancel ends characterID's cast made on sess, if there is one: the job
// dropped, the state set to 0 and broadcast (GObjPC::FUN_00513ea0's success
// path, READ). It reports whether there was one.
func (s *ScrollCaster) cancel(characterID int64, sess *gateway.Session, why string) bool {
	s.mu.Lock()
	c := s.casting[characterID]
	if c == nil || (sess != nil && c.sess != sess) {
		s.mu.Unlock()
		return false
	}
	delete(s.casting, characterID)
	s.mu.Unlock()
	if s.logger != nil {
		s.logger.Info("scroll cast cancelled", "character_id", characterID, "why", why)
	}
	broadcastScrollState(s.hub, characterID, 0)
	return true
}

// cancelRequest is the 0x705B handler (GObjPC::FUN_00513ea0, READ): with no
// scroll working, 0xB05B {2, 6}; else the cast ends, and the 0x30bf value 0
// is the only answer.
func (s *ScrollCaster) cancelRequest(sess *gateway.Session) error {
	var characterID int64 = -1
	if s.hub != nil {
		if e, ok := s.hub.EntityBySession(sess.ID()); ok {
			characterID = e.CharacterID
		}
	}
	if characterID < 0 || !s.cancel(characterID, sess, "the cancel button") {
		return sess.Send(&proto.Packet{Opcode: OpScrollCancelResult, Data: []byte{2, byte(ScrollCancelErrNotCasting), byte(ScrollCancelErrNotCasting >> 8)}})
	}
	return nil
}

func (s *ScrollCaster) table() *teleport.Table {
	if s.network != nil {
		return s.network
	}
	return recallNetwork.Load()
}

// Casting reports whether characterID has a scroll working (vslot 0x120).
func (s *ScrollCaster) Casting(characterID int64) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, ok := s.casting[characterID]
	return ok
}

// placeArrival is where a stored or table point lands: the zone label, hub
// bucket, world position and frame warpTo takes. A dungeon point (a region
// with bit 15) lands in its dungeon at its own height -- a dungeon's floors
// stack -- and a field point in teleportZoneFor's zone at its frame (the
// field's height is the client's to find, as for a gate). ok is false for a
// point OpenSRO cannot place: another game world, a dungeon it does not
// serve, a region of 0.
func placeArrival(region int, x, y, z float64, worldID int) (zone, bucket string, pos world.Position, frame string, ok bool) {
	if region == 0 || (worldID != 0 && worldID != teleport.MainWorld) {
		return "", "", world.Position{}, "", false
	}
	if worldmap.IsDungeonRegion(region) {
		if !ServedDungeon(region) {
			return "", "", world.Position{}, "", false
		}
		zone = worldmap.DungeonZone(region)
		wx, wy, wz := worldmap.DungeonToWorld(x, y, z)
		return zone, zone, world.Position{X: wx, Y: wy, Z: wz}, zone, true
	}
	rx, ry := worldmap.RegionXY(region)
	zone = teleportZoneFor(rx, ry)
	bucket, _, frame, _ = arrival(zone)
	fx, fy, okFrame := worldmap.ParseRegionLabel(frame)
	if !okFrame {
		return "", "", world.Position{}, "", false
	}
	wx, wz := worldmap.ToWorld(rx, ry, x, z, fx, fy)
	return zone, bucket, world.Position{X: wx, Y: y, Z: wz}, frame, true
}

// recordPoint stores where characterID stands now as its point of `kind`
// (SaveCurPosAsLastTelPosition / FUN_004e0330: the region, the position, the
// world). A character not in the world, or in a zone with no frame, records
// nothing; a store that keeps no points (not a ReturnPointStore) is skipped.
func recordPoint(ctx context.Context, chars character.Store, hub *world.Hub, characterID int64, kind character.ReturnPointKind) {
	rs, ok := chars.(character.ReturnPointStore)
	if !ok || hub == nil {
		return
	}
	e, ok := hub.EntityByCharacterID(characterID)
	if !ok {
		return
	}
	place, ok := placeOfEntity(e)
	if !ok || place.Region == 0 {
		return
	}
	p := character.SavedPoint{Region: place.Region, X: place.X, Y: place.Y, Z: place.Z, WorldID: teleport.MainWorld}
	if err := rs.SetReturnPoint(ctx, characterID, kind, p); err != nil {
		slog.Error("recording a return point failed", "character_id", characterID, "kind", kind, "error", err)
	}
}

// recordDeathPoint is the death path's FUN_004e0330: where characterID fell.
func recordDeathPoint(ctx context.Context, chars character.Store, hub *world.Hub, characterID int64) {
	recordPoint(ctx, chars, hub, characterID, character.DeathPoint)
}

// scrollRefusal is a use refused with an engine code and the server's own
// words (the client's fallback).
func scrollRefusal(sess *gateway.Session, code uint16, reason string) error {
	return sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{Error: reason, Code: code}).Encode()})
}

// scrollReason is the server's own wording of a scroll refusal.
func scrollReason(code uint16) string {
	switch code {
	case ScrollErrAlreadyWorking:
		return "a scroll is already working"
	case ScrollErrNoRecallPoint:
		return "there is no last recall point"
	case ScrollErrNoDeathPoint:
		return "there is no last death point"
	case ScrollErrArea:
		return "unable to use that item at this area"
	case ScrollErrLevel:
		return "your level does not allow that destination"
	case ScrollErrWaitReuseDelay:
		return reuseDelayRefusal
	}
	return fmt.Sprintf("that cannot be used (code 0x%x)", code)
}

// use runs one scroll use: the refusals in the engine's order, the item
// spent, the cast started. req carries the reverse scroll's option and map
// id; it is ignored for the return scroll.
func (s *ScrollCaster) use(ctx context.Context, sess *gateway.Session, inv inventory.Store, characterID int64,
	it *refdata.Item, held inventory.Slot, have int, req *UseItemRequest) error {
	refuse := func(code uint16) error {
		if s.logger != nil {
			s.logger.Debug("scroll refused", "character_id", characterID, "item", it.CodeName, "option", req.Option, "code", fmt.Sprintf("0x%x", code))
		}
		return scrollRefusal(sess, code, scrollReason(code))
	}
	reverse := IsReverseReturnScroll(it)
	if !reverse && strings.Contains(strings.ToUpper(it.CodeName), "THIEFDEN") {
		// FUN_004a0380's THIEFDEN branch: job state 2 or 0x186a (round 779,
		// the header); OpenSRO has no thieves.
		return refuse(ScrollErrOnlyRobber)
	}
	if s.hub == nil {
		return refuse(ScrollErrArea)
	}
	if _, inWorld := s.hub.EntityByCharacterID(characterID); !inWorld {
		return refuse(ScrollErrArea)
	}
	// The scroll state (vslot 0x120): one at a time.
	if s.Casting(characterID) {
		return refuse(ScrollErrAlreadyWorking)
	}
	// The item's own reuse delay, as Item_HandleUseItem asks it before DoJob
	// (no retail scroll row carries one; kept for a table that does).
	now := useItemClock()
	if it.CooltimeMs > 0 && !itemCooldowns.ReadyItem(characterID, it.ID, it.CooltimeGroup, now) {
		return refuse(ScrollErrWaitReuseDelay)
	}
	cast := &scrollCast{sess: sess, value: scrollStateValue(it)}
	if reverse {
		cast.option = req.Option
		switch req.Option {
		case ReverseOptionRecall, ReverseOptionDeath:
			kind, code := character.RecallPoint, ScrollErrNoRecallPoint
			if req.Option == ReverseOptionDeath {
				kind, code = character.DeathPoint, ScrollErrNoDeathPoint
			}
			p, ok := s.storedPoint(ctx, characterID, kind)
			if !ok {
				return refuse(code)
			}
			if _, _, _, _, ok := placeArrival(p.Region, p.X, p.Y, p.Z, p.WorldID); !ok {
				return refuse(ScrollErrArea)
			}
		case ReverseOptionMap:
			p, ok := s.table().OptionalByID(int(req.Target))
			if !ok || p.Region == 0 {
				return refuse(ScrollErrUnknownOption)
			}
			c, err := s.chars.GetByID(ctx, characterID)
			if err != nil || c == nil {
				return refuse(ScrollErrUnknownOption)
			}
			if !p.LevelAllows(c.Level) {
				return refuse(ScrollErrLevel)
			}
			if _, _, _, _, ok := placeArrival(p.Region, float64(p.X), float64(p.Y), float64(p.Z), p.WorldID); !ok {
				return refuse(ScrollErrArea)
			}
			cast.point = p
		default:
			return refuse(ScrollErrUnknownOption)
		}
	}
	// Claimed before the item is spent, so a second use racing this one is
	// refused as working rather than both spending a scroll.
	s.mu.Lock()
	if _, busy := s.casting[characterID]; busy {
		s.mu.Unlock()
		return refuse(ScrollErrAlreadyWorking)
	}
	s.casting[characterID] = cast
	s.mu.Unlock()
	if err := inv.RemoveItem(ctx, characterID, held.Index, 1); err != nil {
		s.mu.Lock()
		delete(s.casting, characterID)
		s.mu.Unlock()
		return sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{Error: "using failed"}).Encode()})
	}
	if !reverse {
		// SaveCurPosAsLastTelPosition (0x4a055d): the return scroll's use
		// point becomes the recall point the reverse scroll's option 2 reads.
		recordPoint(ctx, s.chars, s.hub, characterID, character.RecallPoint)
	}
	if it.CooltimeMs > 0 {
		itemCooldowns.ArmItem(characterID, it.ID, it.CooltimeGroup, time.Duration(it.CooltimeMs)*time.Millisecond, now)
	}
	// The stop (slot 300 with its send argument, READ): a leg still running
	// ends where the server has it, and the window -- the user included --
	// hears 0xB023. Then the state and its 0x30bf (FUN_004e0b50).
	if r, moved, ok := s.hub.Halt(sess); ok && moved {
		motions.walking(characterID, time.Now())
		stopRelay(sess, r, true)
	}
	broadcastScrollState(s.hub, characterID, cast.value)
	delay := scrollDelay(it)
	if s.logger != nil {
		s.logger.Info("scroll cast", "character_id", characterID, "item", it.CodeName, "option", cast.option,
			"point", cast.point.ID, "delay", delay, "state", cast.value)
	}
	s.after(delay, func() { s.complete(characterID, cast) })
	return sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{
		Remaining: int32(have - 1), CastMs: uint32(delay / time.Millisecond), ItemID: uint32(it.ID),
	}).Encode()})
}

// storedPoint reads characterID's recall or death point; ok is false when none
// is recorded or the store keeps none.
func (s *ScrollCaster) storedPoint(ctx context.Context, characterID int64, kind character.ReturnPointKind) (character.SavedPoint, bool) {
	rs, ok := s.chars.(character.ReturnPointStore)
	if !ok {
		return character.SavedPoint{}, false
	}
	p, err := rs.ReturnPoint(ctx, characterID, kind)
	if err != nil || !p.Set() {
		return character.SavedPoint{}, false
	}
	return p, true
}

// complete ends a cast: the destination resolved now (the job reads the
// stored points at expiry), then the move -- warpTo's arrival, guarded
// against the mover's stale steps as the return to the return point is.
func (s *ScrollCaster) complete(characterID int64, cast *scrollCast) {
	s.mu.Lock()
	if s.casting[characterID] != cast {
		s.mu.Unlock()
		return
	}
	delete(s.casting, characterID)
	s.mu.Unlock()
	e, ok := s.hub.EntityByCharacterID(characterID)
	if !ok || e.Session != cast.sess || e.Life != world.LifeAlive {
		if s.logger != nil {
			s.logger.Info("scroll cast dropped: the character left, came back elsewhere or died", "character_id", characterID)
		}
		return
	}
	ctx := context.Background()
	// After the move the state returns to 0 (AJStateChanger::vslot_002 case
	// 0xb: vslot 0x378, then FUN_004e0b50(0, ...), READ) and is broadcast
	// where the character now stands. OURS: also when the stored point has
	// gone meanwhile -- the job's `return 0` there leaves the state set until
	// a cancel, which OpenSRO does not copy.
	defer broadcastScrollState(s.hub, characterID, 0)
	if cast.option == 0 {
		_, _ = warpHome(ctx, cast.sess, s.eq, s.chars, s.hub, s.zerk)
		return
	}
	var (
		zone, bucket, frame string
		pos                 world.Position
		placed              bool
	)
	switch cast.option {
	case ReverseOptionRecall, ReverseOptionDeath:
		kind := character.RecallPoint
		if cast.option == ReverseOptionDeath {
			kind = character.DeathPoint
		}
		p, ok := s.storedPoint(ctx, characterID, kind)
		if !ok {
			return // FUN_004e0130 / FUN_004e01c0 answered 0: the job ends
		}
		zone, bucket, pos, frame, placed = placeArrival(p.Region, p.X, p.Y, p.Z, p.WorldID)
	case ReverseOptionMap:
		p := cast.point
		zone, bucket, pos, frame, placed = placeArrival(p.Region, float64(p.X), float64(p.Y), float64(p.Z), p.WorldID)
	}
	if !placed {
		return
	}
	if s.logger != nil {
		s.logger.Info("scroll warp", "character_id", characterID, "option", cast.option, "zone", zone, "x", pos.X, "y", pos.Y, "z", pos.Z)
	}
	armReturnGuard(cast.sess, zone, pos, time.Now())
	moved, _ := warpTo(ctx, cast.sess, s.eq, s.chars, s.hub, s.zerk, zone, bucket, pos, frame)
	if arrived, in := s.hub.EntityBySession(cast.sess.ID()); moved && in {
		bindReturnGuard(cast.sess, arrived.Arrival)
	} else {
		cast.sess.Set(returnGuardKey, (*returnGuard)(nil))
	}
}
