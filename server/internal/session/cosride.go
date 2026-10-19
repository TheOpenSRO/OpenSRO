package session

import (
	"context"
	"encoding/binary"
	"math"
	"sync"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/cos"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// Riding (round 795; docs/protocol/pets.md, "Riding", READ unless marked):
//
//   - 0x70CB {u8 1 mount / 0 dismount, u32 COS uid} (s:0x5119b0). A refusal
//     is 0xB0CB {2, u16 code} to the asker; a mount or dismount is 0xB0CB {1,
//     u32 rider, u8 flag, u32 COS} to everyone who holds the rider, the rider
//     included -- there is no other "is riding" message.
//   - Mounted, the rider takes the COS's walk and run speeds (s:0x4aa410, no
//     multiplier) and its client steers the COS: it sends 0x70C5 {COS uid, 1,
//     movement} where it sent 0x7021, and the server drops a rider's own
//     0x7021. The move is echoed 0xB021 under the COS's uid, and the rider
//     rides along (the COS's mover slots repeat each call on it, s:0x4d29a0..).
//   - Dismounted, the rider's own speeds come back with a 0x30D0 {uid, walk,
//     run}; a ride (TypeID4 1) is then done with: its record is deleted and
//     it leaves the world. A transport stays.
//
// OURS: the server keeps the rider in the hub as it walks (destmove.go's
// mover), and the ridden COS stands where its rider stands.

// OpSpeedChange is retail's 0x30D0 {u32 uid, f32 walk, f32 run}
// (s:0x4aa410, READ), sent when a dismount gives a rider its own speeds back.
const OpSpeedChange uint16 = 0x30D0

// riders is each riding character's COS.
var riders sync.Map // int64 -> *cosObj

// riderMount is characterID's ridden COS, nil when it walks.
func riderMount(characterID int64) *cosObj {
	if v, ok := riders.Load(characterID); ok {
		return v.(*cosObj)
	}
	return nil
}

// forgetRider drops characterID's ride (it left the world).
func forgetRider(characterID int64) { riders.Delete(characterID) }

// moverUID is the uid a character's moves go out under: its ridden COS's
// while it rides (the COS is what moves), else its own.
func moverUID(characterID int64) uint32 {
	if o := riderMount(characterID); o != nil {
		return o.uid
	}
	return uint32(characterID)
}

// riderSpeeds are a rider's walk and run: its COS's while mounted.
func riderSpeeds(characterID int64) (walk, run float64, riding bool) {
	if o := riderMount(characterID); o != nil {
		return o.row.WalkSpeed, o.row.RunSpeed, true
	}
	return 0, 0, false
}

// The mount's refusals (s:0x4fc4d0, READ).
const (
	rideErrMotion = 5
)

// mountCOS puts owner on o (GObjPC::FUN_004ec640). auto is a summon's own
// mount: a refusal there sends nothing (s:0x4fb3cc..0x4fb3f0). The code is
// 0 on success.
func mountCOS(ctx context.Context, sess *gateway.Session, owner int64, o *cosObj, auto bool) int {
	refuse := func(code int) int {
		if !auto && sess != nil {
			_ = sess.Send(&proto.Packet{Opcode: cos.OpCOSRideAck, Data: cos.Refusal(uint16(code))})
		}
		return code
	}
	e, ok := cosOwnerEntity(owner)
	if !ok || e.Life == world.LifeDead {
		return refuse(cos.ErrRideGeneric)
	}
	now := time.Now()
	if e.Move != nil || motions.sittingOrSittingDown(owner, now) {
		return refuse(rideErrMotion)
	}
	if o == nil || o.owner != owner {
		return refuse(cos.ErrRideNotFound)
	}
	if riderMount(owner) != nil {
		return refuse(cos.ErrRideAlready)
	}
	// CanBeVehicle (characterdata col 66): 1 on every ride and transport row,
	// on no pet's (MEASURED).
	if o.kind != cos.KindRide && o.kind != cos.KindTransport {
		return refuse(cos.ErrRideNotRideable)
	}
	cosWorld.mu.Lock()
	pos := o.at(now)
	if o.dead {
		cosWorld.mu.Unlock()
		return refuse(cos.ErrRideGeneric)
	}
	cosWorld.mu.Unlock()
	if cosDistance(pos, e.Pos) > cos.MountRange {
		return refuse(cos.ErrRideTooFar)
	}
	cosWorld.mu.Lock()
	o.ridden, o.moving, o.pos, o.heading = true, false, e.Pos, e.Heading
	cosWorld.mu.Unlock()
	riders.Store(owner, o)
	bumpPlayerState(owner)
	sendAboutPlayerPacket(cosWorld.depsNow().hub, owner, true, cos.OpCOSRideAck, cos.RideAck(uint32(owner), true, o.uid))
	return 0
}

// dismountCOS takes owner off o (GObjPC::FUN_004ec750). released is a
// dismount inside a release, which settles the COS itself; otherwise a ride
// is done with and released (deleted) here.
func dismountCOS(owner int64, o *cosObj, released bool) {
	if riderMount(owner) != o {
		return
	}
	riders.Delete(owner)
	now := time.Now()
	pos := o.pos
	if e, ok := cosOwnerEntity(owner); ok {
		pos = e.Pos
		if e.Move != nil {
			if p, _ := e.Move.At(now); p != (world.Position{}) {
				pos = p
			}
		}
	}
	cosWorld.mu.Lock()
	o.ridden, o.pos, o.moving = false, pos, false
	kind := o.kind
	cosWorld.mu.Unlock()
	bumpPlayerState(owner)
	hub := cosWorld.depsNow().hub
	// The rider's own speeds, told with 0x30D0 (s:0x4aa410).
	speed := binary.LittleEndian.AppendUint32(nil, uint32(owner))
	speed = binary.LittleEndian.AppendUint32(speed, math.Float32bits(PlayerWalkSpeed))
	speed = binary.LittleEndian.AppendUint32(speed, math.Float32bits(float32(buffBooks.RunSpeed(owner))))
	sendAboutPlayerPacket(hub, owner, true, OpSpeedChange, speed)
	if !released && kind == cos.KindRide {
		releaseCOS(context.Background(), o, releaseDelete)
	}
	sendAboutPlayerPacket(hub, owner, true, cos.OpCOSRideAck, cos.RideAck(uint32(owner), false, o.uid))
}

// handleRide is 0x70CB.
func handleRide(ctx context.Context, sess *gateway.Session, characterID int64, data []byte) error {
	if len(data) < 5 {
		return sess.Send(&proto.Packet{Opcode: cos.OpCOSRideAck, Data: cos.Refusal(2)})
	}
	uid := binary.LittleEndian.Uint32(data[1:])
	switch data[0] {
	case 1:
		if uid == 0 {
			return sess.Send(&proto.Packet{Opcode: cos.OpCOSRideAck, Data: cos.Refusal(cos.ErrRideNothingRidden)})
		}
		mountCOS(ctx, sess, characterID, cosWorld.ownedOf(characterID, uid), false)
	case 0:
		o := riderMount(characterID)
		if o == nil {
			return sess.Send(&proto.Packet{Opcode: cos.OpCOSRideAck, Data: cos.Refusal(cos.ErrRideAlready)})
		}
		dismountCOS(characterID, o, false)
	default:
		return sess.Send(&proto.Packet{Opcode: cos.OpCOSRideAck, Data: cos.Refusal(2)})
	}
	return nil
}

// cosTakeDamage is a blow on o: its HP down, its owner told, and at 0 its
// death -- a ride's or transport's release with its record deleted, its rider
// dismounted (CGObjCOS_Cart's die slots s:0x52a000 / 0x52d1b0 ->
// PC_ReleaseCOS(kind 1), READ), a pet's corpse (s:0x529f70, kind 8).
func cosTakeDamage(o *cosObj, dmg int) {
	cosWorld.mu.Lock()
	if o.dead {
		cosWorld.mu.Unlock()
		return
	}
	o.rec.HP -= dmg
	if o.rec.HP < 0 {
		o.rec.HP = 0
	}
	hp, kind := o.rec.HP, o.kind
	cosWorld.mu.Unlock()
	sendCOSHP(o, hp)
	if hp > 0 {
		return
	}
	ctx := context.Background()
	if cos.IsPetKind(kind) {
		cosDied(ctx, o)
		return
	}
	releaseCOS(ctx, o, releaseDelete)
}

// cosDied is a pet's death: it lies dead (life 2, its 0x3057-equivalent
// through the HP push) until its corpse is cleared, and its record says dead
// (PC_ReleaseCOS(uid, 8, 1): the item's state 4, 0x30C9 type 1 to the owner).
func cosDied(ctx context.Context, o *cosObj) {
	// A growth pet's EXP loss (GObjCOS_Pet::FUN_004d6c80, READ): by its
	// level's threshold and unit; killed by a monster (OpenSRO's COS take
	// blows from nothing else), its owner no murderer (no PvP states).
	cosWorld.mu.Lock()
	growth, level := o.kind == cos.KindGrowth, o.rec.Level
	cosWorld.mu.Unlock()
	if growth && levelTable != nil {
		next, _ := levelTable.ExpToNext(level)
		unit, _ := levelTable.ExpUnit(level)
		if loss := cos.DeathExpLoss(next, unit, false, false); loss > 0 {
			cosGainExp(ctx, o, -loss, 0, 0)
		}
	}
	cosWorld.mu.Lock()
	o.dead, o.moving, o.target, o.pick = true, false, 0, 0
	o.legStart = time.Now()
	rec := o.rec
	rec.State = 0
	o.rec.State = 0
	owner, itemID := o.owner, o.itemID
	cosWorld.mu.Unlock()
	d := cosWorld.depsNow()
	if d.store != nil {
		_ = d.store.Save(ctx, rec)
	}
	sendToCOSOwner(o, cos.OpCOSUpdate, cos.RemovedUpdate(o.uid))
	if itemID != 0 {
		if slot, ok := cosItemSlot(ctx, owner, rec.ID); ok {
			if e, ok := cosOwnerEntity(owner); ok {
				sendItemState(e.Session, slot, cos.ItemStateDead)
			}
		}
	}
	// Everyone holding the owner sees it fall (a respawned record, life 2).
	cosAnnounce(o, cosSpawnTypeKnown)
}

// cosOwnerDied is an owner's death: the COS it rides is done with
// (CGObjPC vslot_306/307 -> PC_ReleaseCOS(ridden, 1), READ). Its pets stay.
func cosOwnerDied(characterID int64) {
	if o := riderMount(characterID); o != nil {
		releaseCOS(context.Background(), o, releaseDelete)
	}
}
