package session

import (
	"context"
	"encoding/binary"
	"sync"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/cos"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/pcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Job suits and job mode (round 800; docs/protocol/jobs.md "The job suit").
// READ, SR_GameServer.exe:
//
//   - Every move into or out of equip slot 8 goes through FUN_00524950 (wear)
//     and FUN_00524b20 (take off). A wear into an occupied slot 8 is 0x1846;
//     the generic equip tests follow; then, for a job suit (TypeID
//     3/1/7/1..3), CGItemEquip::vslot_302 (s:0x497630) and the world
//     context's slot 6 (s:0x5297e0): riding 0x18ca, a job change pending
//     0x1847, the suit's job not the character's 0x189e, no alias 0x189f,
//     not in a town 0x18a2, in a party 0x18a0, then the job level below the
//     suit's second requirement 0x18a3 (WEARLIMIT).
//   - Taking a suit off (vslot_301, s:0x497510): a change pending 0x1847, no
//     free bag slot 0x1807, riding 0x18ca, the battle state 0x1848, a
//     transport out 0x185a, within 10 s of wearing it 0x1847, a party 0x18a0,
//     not in a town 0x18a2.
//   - Neither is instant: CGObjPC::FUN_004e0c60(1) starts a 10-second
//     AJStateChanger (kind 0xe, 10.0 at s:0xb45b44), sets chardata+0x13 and
//     tells the 3x3 0x3041 {u32 uid, u8 2, u8 2, u8 10}; the request answers
//     nothing (0x189b, which StorageOperation swallows). Entering battle,
//     being hit, a movement request or any other storage operation cancels
//     it: 0x3042 {u32 uid, u8 0} to the 3x3. After 10 s the tests run again,
//     the item moves, 0x3038 / 0x3039 go to the 3x3, the job state is set
//     (chardata+0xf: the suit's TypeID4, or 4), a wear arms the 10-second
//     take-off lock (PC+0x2178), and every owned COS tells its owner's job
//     0x30CA {uid, mask 1, job}. Nothing else is sent: no respawn and no name
//     message, so the players in view keep the name they spawned with.
//
// OURS (disclosed): the stall network's 0x18cd and the PvP cape's 0x18a3 are
// not tested (OpenSRO has neither); the siege world's blanket 0x18a2 is not
// modelled; with no town table (-regions-csv unset) every place counts as a
// town; the 10-second clocks are wall-clock timers where the engine ticks at
// 1 Hz.

// The suit's codes (READ above; docs/protocol/error_codes.md's names).
const (
	suitErrInvFull       uint16 = 0x1807
	suitErrStorageBusy   uint16 = 0x180e
	suitErrLevel         uint16 = 0x1810
	suitErrGender        uint16 = 0x1816
	suitErrCountry       uint16 = 0x182f
	suitErrSwap          uint16 = 0x1846
	suitErrPending       uint16 = 0x1847
	suitErrBattle        uint16 = 0x1848
	suitErrCart          uint16 = 0x185a
	suitErrRide          uint16 = 0x18ca
	suitErrNoJob         uint16 = 0x189e
	suitErrNoAlias       uint16 = 0x189f
	suitErrParty         uint16 = 0x18a0
	suitErrNotTown       uint16 = 0x18a2
	suitErrWearLimit     uint16 = 0x18a3
	jobChangeSeconds            = 10
	jobWearLockSeconds          = 10
	OpStripStart         uint16 = 0x3041
	OpStripCancel        uint16 = 0x3042
	stripKindJob         byte   = 2
	stripSubJob          byte   = 2
	cosOwnerStateJobMask byte   = 1
)

// suitErrKeys are the client's messages for the suit's codes: the error's
// text is the key, which OpenSRO's client resolves (OpEquipmentResult has no
// code field; OURS).
var suitErrKeys = map[uint16]string{
	suitErrInvFull:     "UIIT_MSG_STRGERR_INVENTORY_FULL",
	suitErrStorageBusy: "UIIT_MSG_STRGERR_EQUIPITEM",
	suitErrLevel:       "UIIT_MSG_STRGERR_HIGHER_LEVEL_REQUIRED",
	suitErrGender:      "UIIT_MSG_STRGERR_GENDER_MISMATCH",
	suitErrCountry:     "UIIT_MSG_STRGERR_COUNTRY_MISMATCH",
	suitErrSwap:        "UIIT_MSG_STRGERR_CANT_SWAP_JOBITEM",
	suitErrPending:     "UIIT_MSG_STRGERR_WAIT_FOR_JOBCHANGE_COMPLETE",
	suitErrBattle:      "UIIT_MSG_STRGERR_CANT_DETACH_JOBITEM_IN_BATTLESTATE",
	suitErrCart:        "UIIT_MSG_STRGERR_CANT_HAVE_CART",
	suitErrRide:        "UIIT_MSG_JOBITEM_WEAR_ERR_RIDE",
	suitErrNoJob:       "UIIT_MSG_JOBITEM_WEAR_ERR_NOJOB",
	suitErrNoAlias:     "UIIT_MSG_JOBITEM_WEAR_ERR_NOALIAS",
	suitErrParty:       "UIIT_MSG_JOBITEM_WEAR_ERR_PARTY",
	suitErrNotTown:     "UIIT_MSG_JOBITEM_WEAR_ERR_NOPOSITION",
	suitErrWearLimit:   "UIIT_MSG_JOBITEM_WEAR_ERR_WEARLIMIT",
}

// isJobSuit is the server's "is job suit" (s:0x489020, item vslot 0x414):
// TypeID 3/1/7 with TypeID4 1, 2 or 3.
func isJobSuit(it *refdata.Item) bool {
	return it != nil && it.TypeID1 == 3 && it.TypeID2 == 1 && it.TypeID3 == 7 && it.TypeID4 >= 1 && it.TypeID4 <= 3
}

// jobStates is each character's job state (chardata+0xf): the worn suit's,
// cached at world entry and on every change (round 800).
var jobStates sync.Map // int64 -> byte

// jobStateNow is characterID's job state: 1 trader, 2 thief, 3 hunter, 4 none.
func jobStateNow(ctx context.Context, characterID int64) byte {
	if v, ok := jobStates.Load(characterID); ok {
		return v.(byte)
	}
	s := wornJobState(ctx, characterID)
	jobStates.Store(characterID, s)
	return s
}

// inJobMode reports a character wearing a job suit.
func inJobMode(ctx context.Context, characterID int64) bool {
	return jobStateNow(ctx, characterID) != pcspawn.JobStateNone
}

// jobChange is a pending suit change (chardata+0x13 set).
type jobChange struct {
	wear    bool
	invSlot int
	timer   *time.Timer
}

var jobChanges = struct {
	mu sync.Mutex
	m  map[int64]*jobChange
}{m: map[int64]*jobChange{}}

// jobWearLocks is PC+0x2178: when the 10 seconds after a wear end.
var jobWearLocks sync.Map // int64 -> time.Time

func jobChangePending(characterID int64) bool {
	jobChanges.mu.Lock()
	defer jobChanges.mu.Unlock()
	return jobChanges.m[characterID] != nil
}

// suitDeps is what the suit's tests read.
type suitDeps struct {
	ctx   context.Context
	store equipment.Store
	inv   inventory.Store
	items ItemLookup
	hub   *world.Hub
}

// inTownAt reports whether e stands in a town region (the region row's
// IsBattleField 0). With no town table everything is a town (OURS).
func inTownAt(e world.Entity) bool {
	if safeRegions.Load() == nil {
		return true
	}
	_, ok := safeRegionAt(e.Zone, e.Pos.X, e.Pos.Z)
	return ok
}

// inAParty reports a character in a party.
func inAParty(characterID int64) bool {
	d := jobDepsNow()
	if d.parties == nil {
		return false
	}
	_, ok := d.parties.Get(characterID)
	return ok
}

// suitWearCode is the wear's job-suit tests (vslot_302 and the world context,
// in their order) for item, worn by e. 0 passes.
func suitWearCode(ctx context.Context, e world.Entity, item *refdata.Item) uint16 {
	if riderMount(e.CharacterID) != nil {
		return suitErrRide
	}
	if jobChangePending(e.CharacterID) || jobStateNow(ctx, e.CharacterID) != pcspawn.JobStateNone {
		return suitErrPending
	}
	rec := jobRecord(ctx, e.CharacterID)
	if int(rec.Kind) != item.TypeID4 {
		return suitErrNoJob
	}
	if rec.Alias == "" {
		return suitErrNoAlias
	}
	if !inTownAt(e) {
		return suitErrNotTown
	}
	if inAParty(e.CharacterID) {
		return suitErrParty
	}
	if item.ReqLevelType2 >= 0 && rec.Level < item.ReqLevel2 {
		return suitErrWearLimit
	}
	return 0
}

// suitTakeOffCode is the take-off's tests (FUN_00524b20, vslot_301).
func suitTakeOffCode(ctx context.Context, d suitDeps, e world.Entity, now time.Time) uint16 {
	if jobChangePending(e.CharacterID) {
		return suitErrPending
	}
	if d.inv != nil {
		slots, err := d.inv.List(ctx, e.CharacterID)
		if err == nil && len(slots) >= inventory.PlacementCapacityOf(ctx, d.inv, e.CharacterID) {
			return suitErrInvFull
		}
	}
	if riderMount(e.CharacterID) != nil {
		return suitErrRide
	}
	if inBattle(e.CharacterID, now) {
		return suitErrBattle
	}
	if ownsTransport(e.CharacterID) {
		return suitErrCart
	}
	if v, ok := jobWearLocks.Load(e.CharacterID); ok && now.Before(v.(time.Time)) {
		return suitErrPending
	}
	if inAParty(e.CharacterID) {
		return suitErrParty
	}
	if !inTownAt(e) {
		return suitErrNotTown
	}
	return 0
}

// ownsTransport reports a summoned transport (CGObjPC::IHaveCart).
func ownsTransport(owner int64) bool {
	for _, o := range cosWorld.owned(owner) {
		if o.kind == cos.KindTransport {
			return true
		}
	}
	return false
}

func suitRefusal(sess *gateway.Session, code uint16) error {
	return sess.Send(&proto.Packet{Opcode: OpEquipmentResult, Data: (&EquipmentResult{Error: suitErrKeys[code]}).Encode()})
}

// stripFrame is 0x3041 {u32 uid, u8 2, u8 2, u8 10}.
func stripStart(characterID int64) []byte {
	out := binary.LittleEndian.AppendUint32(nil, uint32(characterID))
	return append(out, stripKindJob, stripSubJob, jobChangeSeconds)
}

// beginJobChange starts the 10 seconds (FUN_004e0c60(PC, 1)).
func beginJobChange(sess *gateway.Session, d suitDeps, characterID int64, wear bool, invSlot int) {
	ch := &jobChange{wear: wear, invSlot: invSlot}
	jobChanges.mu.Lock()
	jobChanges.m[characterID] = ch
	jobChanges.mu.Unlock()
	sendAboutPlayerPacket(d.hub, characterID, true, OpStripStart, stripStart(characterID))
	ch.timer = time.AfterFunc(jobChangeSeconds*time.Second, func() { finishJobChange(sess, d, characterID, ch) })
}

// cancelJobChange is FUN_004e0c60(PC, 0) with time left: the change is
// dropped and the 3x3 told 0x3042 {uid, 0}.
func cancelJobChange(hub *world.Hub, characterID int64) {
	jobChanges.mu.Lock()
	ch := jobChanges.m[characterID]
	delete(jobChanges.m, characterID)
	jobChanges.mu.Unlock()
	if ch == nil {
		return
	}
	if ch.timer != nil {
		ch.timer.Stop()
	}
	out := binary.LittleEndian.AppendUint32(nil, uint32(characterID))
	sendAboutPlayerPacket(hub, characterID, true, OpStripCancel, append(out, 0))
}

// finishJobChange is AJStateChanger::vslot_002 case 0xe (s:0x405f70): the
// tests again, the move, then the state.
func finishJobChange(sess *gateway.Session, d suitDeps, characterID int64, ch *jobChange) {
	jobChanges.mu.Lock()
	if jobChanges.m[characterID] != ch {
		jobChanges.mu.Unlock()
		return
	}
	delete(jobChanges.m, characterID)
	jobChanges.mu.Unlock()
	ctx := d.ctx
	if ctx == nil {
		ctx = context.Background()
	}
	e, ok := entityOf(d.hub, characterID)
	if !ok {
		return
	}
	now := time.Now()
	if ch.wear {
		item := bagItem(ctx, d, characterID, ch.invSlot)
		if item == nil || !isJobSuit(item) {
			return
		}
		if code := suitWearCode(ctx, e, item); code != 0 {
			_ = suitRefusal(sess, code)
			return
		}
		if err := d.store.Equip(ctx, characterID, equipment.SlotJobSuit, ch.invSlot); err != nil {
			_ = sess.Send(&proto.Packet{Opcode: OpEquipmentResult, Data: (&EquipmentResult{Error: equipErrorMessage(err)}).Encode()})
			return
		}
		jobWearLocks.Store(characterID, now.Add(jobWearLockSeconds*time.Second))
		setJobState(ctx, characterID, byte(item.TypeID4))
		_ = sendWornList(ctx, sess, d.store, d.items, characterID)
		broadcastWorn(ctx, d.hub, d.store, d.items, characterID, equipment.SlotJobSuit)
		return
	}
	if code := suitTakeOffCode(ctx, d, e, now); code != 0 && code != suitErrPending {
		_ = suitRefusal(sess, code)
		return
	}
	removed := wornIn(ctx, d.store, characterID, equipment.SlotJobSuit)
	if err := d.store.Unequip(ctx, characterID, equipment.SlotJobSuit); err != nil {
		_ = sess.Send(&proto.Packet{Opcode: OpEquipmentResult, Data: (&EquipmentResult{Error: equipErrorMessage(err)}).Encode()})
		return
	}
	setJobState(ctx, characterID, pcspawn.JobStateNone)
	// The suit off ends a safe trade (round 802, s:0x4f0dd4).
	safeTradeLose(ctx, characterID)
	_ = sendWornList(ctx, sess, d.store, d.items, characterID)
	broadcastUnworn(d.hub, characterID, equipment.SlotJobSuit, removed)
}

// setJobState is FUN_004e0b20: chardata+0xf, then every owned COS tells the
// owner's job (0x30CA mask 1, GObjPC::FUN_004fc880(1) -> FUN_004d1ea0).
func setJobState(ctx context.Context, characterID int64, state byte) {
	jobStates.Store(characterID, state)
	invalidateLook(characterID)
	for _, o := range cosWorld.owned(characterID) {
		sendAboutCOS(o, cos.OpCOSOwnerState, cos.OwnerJobState(o.uid, state))
		// Round 815 (OURS): the COS spawned again in place for everyone who
		// holds it, so its owner line ("*alias" in a suit, the name out of
		// one, ICCos::FUN_009c5ea0) is rebuilt. READ: the original client
		// builds that line only at the COS's spawn (CICCos::vslot_025) and
		// 0x30CA's mask 1 only stores the job byte (slot 44, +0x50d); how
		// the original refreshed it after a suit change is OPEN (jobs.md).
		// The user (round 815): a pet kept "*alias" after the suit came off.
		cosAnnounce(o, cosSpawnTypeKnown)
	}
}

// bagItem is the reference row of the item in characterID's bag slot.
func bagItem(ctx context.Context, d suitDeps, characterID int64, slot int) *refdata.Item {
	if d.inv == nil || d.items == nil {
		return nil
	}
	slots, err := d.inv.List(ctx, characterID)
	if err != nil {
		return nil
	}
	for _, s := range slots {
		if s.Index == slot {
			it, err := d.items.GetItem(ctx, s.ItemID)
			if err != nil {
				return nil
			}
			return it
		}
	}
	return nil
}

// storageOpDuringChange is StorageOperation's first test (s:0x50f852): any
// storage operation while a suit change is pending cancels it and is refused
// 0x180e. True when it refused.
func storageOpDuringChange(sess *gateway.Session, hub *world.Hub, characterID int64) bool {
	// Round 869: the session's own world (gameworlds.go).
	hub = hub.For(sess)
	if !jobChangePending(characterID) {
		return false
	}
	cancelJobChange(hub, characterID)
	_ = suitRefusal(sess, suitErrStorageBusy)
	return true
}

// slot8Taken is FUN_00524950's test before the generic ones: anything worn in
// slot 8 refuses a wear into it (0x1846, capes too).
func slot8Taken(ctx context.Context, store equipment.Store, characterID int64) bool {
	return wornIn(ctx, store, characterID, equipment.SlotJobSuit) != 0
}

// jobSuitEquip takes an equip into slot 8 (handled true) or leaves it to the
// ordinary path (false: not a job suit). The caller ran slot8Taken and the
// generic tests.
func jobSuitEquip(ctx context.Context, sess *gateway.Session, d suitDeps, characterID int64, invSlot int) (bool, error) {
	item := bagItem(ctx, d, characterID, invSlot)
	if !isJobSuit(item) {
		return false, nil
	}
	e, ok := entityOf(d.hub, characterID)
	if !ok {
		return true, nil
	}
	if code := suitWearCode(ctx, e, item); code != 0 {
		return true, suitRefusal(sess, code)
	}
	beginJobChange(sess, d, characterID, true, invSlot)
	return true, nil
}

// jobSuitUnequip takes a take-off from slot 8 when a job suit is worn there.
func jobSuitUnequip(ctx context.Context, sess *gateway.Session, d suitDeps, characterID int64) (bool, error) {
	worn := wornIn(ctx, d.store, characterID, equipment.SlotJobSuit)
	if worn == 0 || d.items == nil {
		return false, nil
	}
	it, err := d.items.GetItem(ctx, worn)
	if err != nil || !isJobSuit(it) {
		return false, nil
	}
	e, ok := entityOf(d.hub, characterID)
	if !ok {
		return true, nil
	}
	if code := suitTakeOffCode(ctx, d, e, time.Now()); code != 0 {
		return true, suitRefusal(sess, code)
	}
	beginJobChange(sess, d, characterID, false, -1)
	return true, nil
}

// forgetJobMode drops a leaving character's runtime job state.
func forgetJobMode(characterID int64) {
	jobChanges.mu.Lock()
	if ch := jobChanges.m[characterID]; ch != nil && ch.timer != nil {
		ch.timer.Stop()
	}
	delete(jobChanges.m, characterID)
	jobChanges.mu.Unlock()
	jobStates.Delete(characterID)
	jobWearLocks.Delete(characterID)
	battleStates.Delete(characterID)
}

// The battle state (round 800; READ GObjPC::SetBattleState s:0x4e2910): set
// by a blow given or taken, it lasts 20 s (PC+0x203c = 0x14, ticked at 1 Hz).
// Combat also cancels a pending suit change (GObjPC::FUN_004e1df0) and ends
// the wear's 10-second lock early, telling 0x30CF {uid, job state}
// (FUN_004e1ef0). OURS (disclosed): retail tells every change as 0x30BF kind
// 8; OpenSRO keeps the state on the server only (its client draws no battle
// state, and the message would land between every blow and its reply).
const (
	battleSeconds        = 20
	OpJobLockEnd  uint16 = 0x30CF
)

type battleState struct {
	until time.Time
}

var battleStates sync.Map // int64 -> *battleState

func inBattle(characterID int64, now time.Time) bool {
	v, ok := battleStates.Load(characterID)
	return ok && now.Before(v.(*battleState).until)
}

// markBattle is a blow given or taken by characterID.
func markBattle(hub *world.Hub, characterID int64, now time.Time) {
	if hub == nil {
		return
	}
	cancelJobChange(hub, characterID)
	if v, ok := jobWearLocks.Load(characterID); ok && now.Before(v.(time.Time)) {
		jobWearLocks.Delete(characterID)
		out := binary.LittleEndian.AppendUint32(nil, uint32(characterID))
		sendAboutPlayerPacket(hub, characterID, true, OpJobLockEnd, append(out, jobStateNow(context.Background(), characterID)))
	}
	battleStates.Store(characterID, &battleState{until: now.Add(battleSeconds * time.Second)})
}
