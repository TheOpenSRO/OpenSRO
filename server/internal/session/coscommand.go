package session

import (
	"context"
	"encoding/binary"
	"errors"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/cos"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// The client's COS requests (round 795; docs/protocol/pets.md, "Round 795",
// READ unless marked):
//
//	0x70C5 {u32 uid, u8 command, ...}   s:0x511de0 -> GObjPC::FUN_004d2200
//	0x70C6 {u32 uid}                    s:0x511e00, terminate a ride or transport
//	0x70CB {u8 1|0, u32 uid}            s:0x5119b0, mount / dismount (cosride.go)
//	0x7116 {u32 uid}                    s:0x511a60, put a pet away
//	0x7117 {u32 uid, string name}       s:0x511bb0, name a pet (once)
//	0x7420 {u32 uid, u8 kind, u32 v}    s:0x511d10, a pet's setting

// COSHandler returns the handler for the COS requests.
func COSHandler(hub *world.Hub, chars character.Store) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		// Round 869: the session's own world (gameworlds.go).
		hub := hub.For(sess)
		switch p.Opcode {
		case cos.OpCOSCommand, cos.OpCOSTerminate, cos.OpCOSRide, cos.OpCOSUnsummon, cos.OpCOSName, cos.OpCOSSetting:
		default:
			return nil
		}
		e, ok := hub.EntityBySession(sess.ID())
		if !ok {
			return nil
		}
		owner := e.CharacterID
		switch p.Opcode {
		case cos.OpCOSRide:
			return handleRide(ctx, sess, owner, p.Data)
		case cos.OpCOSCommand:
			return handleCOSCommand(sess, owner, e, p.Data, hub, chars)
		case cos.OpCOSTerminate:
			return handleCOSTerminate(ctx, sess, owner, p.Data)
		case cos.OpCOSUnsummon:
			return handleCOSUnsummon(ctx, sess, e, p.Data)
		case cos.OpCOSName:
			return handleCOSName(ctx, sess, owner, p.Data)
		case cos.OpCOSSetting:
			return handleCOSSetting(ctx, sess, owner, p.Data)
		}
		return nil
	}
}

// cosReply sends a COS reply's two-field refusal.
func cosReply(sess *gateway.Session, op uint16, code int) error {
	return sess.Send(&proto.Packet{Opcode: op, Data: cos.Refusal(uint16(code))})
}

// handleCOSCommand is 0x70C5. Its handler returns its codes to a caller
// that sends nothing for them (0x4406 no such COS, 0x4407 not controllable:
// OPEN how the client hears them), so those are silent here.
func handleCOSCommand(sess *gateway.Session, owner int64, e world.Entity, data []byte, hub *world.Hub, chars character.Store) error {
	// Round 869: the session's own world (gameworlds.go).
	hub = hub.For(sess)
	if len(data) < 5 {
		return nil
	}
	uid := binary.LittleEndian.Uint32(data)
	cmd := data[4]
	o := cosWorld.ownedOf(owner, uid)
	if cosTrace {
		cosWorld.depsNow().logger.Info("cos: command", "owner", owner, "cos", uid, "command", cmd, "found", o != nil)
	}
	if o == nil {
		return nil
	}
	body := data[5:]
	switch cmd {
	case cos.CommandMove:
		// The controlled object's move: the client steers what it rides
		// (c:FUN_009ebd10). The owner in an interaction drops it silently.
		if riderMount(owner) == o {
			return riderMove(sess, body, hub, chars)
		}
	case cos.CommandStop, cos.CommandTurn:
		// Round 808: the arrow keys ridden (READ client side; the server's
		// FUN_004d2200 cases 3 / 4 are not read -- INFERRED to be the ridden
		// 0x7023 / 0x7024): the rider is what the hub moves, and its stop and
		// turn go out under the COS's uid (moverUID).
		if riderMount(owner) == o {
			if cmd == cos.CommandStop {
				return arrowStop(sess, body, hub)
			}
			return arrowTurn(sess, body, hub)
		}
	case cos.CommandAttack:
		if len(body) < 4 {
			return nil
		}
		target := binary.LittleEndian.Uint32(body)
		cosWorld.mu.Lock()
		if o.kind == cos.KindGrowth && !o.dead {
			o.target, o.pick = int64(target), 0
		}
		cosWorld.mu.Unlock()
	case cos.CommandPick:
		if len(body) < 4 {
			return nil
		}
		item := binary.LittleEndian.Uint32(body)
		cosWorld.mu.Lock()
		kind, dead, busy := o.kind, o.dead, o.pick != 0 && o.pick != int64(item)
		if kind == cos.KindAbility && !dead && !busy {
			o.pick, o.target = int64(item), 0
		}
		cosWorld.mu.Unlock()
		if kind != cos.KindAbility {
			return nil // return 3: no reply (s:0x4d2667)
		}
		if dead || busy {
			// The state refused the pick (PICKITEM approaching): 0x189c.
			return sess.Send(&proto.Packet{Opcode: cos.OpCOSCommandAck, Data: pickFail(o.uid, item, cosPickBusy)})
		}
	case cos.CommandFollow:
		cosWorld.mu.Lock()
		o.target, o.pick = 0, 0
		cosWorld.mu.Unlock()
	}
	return nil
}

// cosPickBusy is 0x189c, a pick the pet's state refuses (READ).
const cosPickBusy = 0x189c

// pickFail is 0xB0C5 {2, 8, u16 code, u32 pet, u32 item}.
func pickFail(pet, item uint32, code uint16) []byte {
	out := binary.LittleEndian.AppendUint16([]byte{2, cos.CommandPick}, code)
	out = binary.LittleEndian.AppendUint32(out, pet)
	return binary.LittleEndian.AppendUint32(out, item)
}

// pickOK is 0xB0C5 {1, 8, u32 pet, u32 item}.
func pickOK(pet, item uint32) []byte {
	out := binary.LittleEndian.AppendUint32([]byte{1, cos.CommandPick}, pet)
	return binary.LittleEndian.AppendUint32(out, item)
}

// handleCOSTerminate is 0x70C6: a ride or transport is done with (its
// record deleted); a pet is refused 5.
func handleCOSTerminate(ctx context.Context, sess *gateway.Session, owner int64, data []byte) error {
	if len(data) < 4 {
		return cosReply(sess, cos.OpCOSTermAck, cos.ErrCOSTerminateNotFound)
	}
	o := cosWorld.ownedOf(owner, binary.LittleEndian.Uint32(data))
	if o == nil || cos.IsPetKind(o.kind) {
		return cosReply(sess, cos.OpCOSTermAck, cos.ErrCOSTerminateNotFound)
	}
	// A transport's goods fall to the ground first, unowned (round 801:
	// the handler calls slot 398 with killer 0, s:0x511e00).
	dropTransportGoods(ctx, o, 0)
	releaseCOS(ctx, o, releaseDelete)
	return sess.Send(&proto.Packet{Opcode: cos.OpCOSTermAck, Data: []byte{1}})
}

// handleCOSUnsummon is 0x7116: a pet put back in its item. No reply on
// success (MEASURED: the server's only 0xB116 is the refusal).
func handleCOSUnsummon(ctx context.Context, sess *gateway.Session, e world.Entity, data []byte) error {
	if e.Life == world.LifeDead {
		return cosReply(sess, cos.OpCOSUnsumAck, cos.ErrPetUnsummonDead)
	}
	if len(data) < 4 {
		return cosReply(sess, cos.OpCOSUnsumAck, cos.ErrCOSCommandNoSuchCOS)
	}
	o := cosWorld.ownedOf(e.CharacterID, binary.LittleEndian.Uint32(data))
	if o == nil {
		return cosReply(sess, cos.OpCOSUnsumAck, cos.ErrCOSCommandNoSuchCOS)
	}
	cosWorld.mu.Lock()
	pos, itemID := o.at(time.Now()), o.itemID
	cosWorld.mu.Unlock()
	if cosDistance(pos, e.Pos) >= cos.RecallRange {
		return cosReply(sess, cos.OpCOSUnsumAck, cos.ErrCOSCommandTooFar)
	}
	if itemID == 0 {
		return cosReply(sess, cos.OpCOSUnsumAck, cos.ErrCOSUnsummonItemAbsent)
	}
	releaseCOS(ctx, o, releaseStore)
	return nil
}

// handleCOSName is 0x7117 (HandleNameCOS s:0x511bb0): a pet named once.
// No 0xB117 on success: the name goes out as 0x30C9 type 5.
func handleCOSName(ctx context.Context, sess *gateway.Session, owner int64, data []byte) error {
	if len(data) < 6 {
		return cosReply(sess, cos.OpCOSNameAck, cos.ErrRideGeneric)
	}
	uid := binary.LittleEndian.Uint32(data)
	n := int(binary.LittleEndian.Uint16(data[4:]))
	if n == 0 || n > cos.MaxNameLength || len(data) < 6+n {
		return cosReply(sess, cos.OpCOSNameAck, cos.ErrRideGeneric)
	}
	name := string(data[6 : 6+n])
	if !cos.ValidPetName(name) {
		return cosReply(sess, cos.OpCOSNameAck, cos.ErrPetNameNotAllowed)
	}
	if f := nameFilter.Load(); f != nil && !f.NameOK(name) {
		return cosReply(sess, cos.OpCOSNameAck, cos.ErrPetNameNotAllowed)
	}
	o := cosWorld.ownedOf(owner, uid)
	if o == nil {
		return cosReply(sess, cos.OpCOSNameAck, cos.ErrCOSCommandNoSuchCOS)
	}
	cosWorld.mu.Lock()
	named, id, isPet := o.rec.Name != "", o.rec.ID, cos.IsPetKind(o.kind)
	cosWorld.mu.Unlock()
	if named || !isPet {
		return cosReply(sess, cos.OpCOSNameAck, cos.ErrRideGeneric)
	}
	d := cosWorld.depsNow()
	if err := d.store.SetName(ctx, id, name); err != nil {
		if errors.Is(err, cos.ErrNameTaken) {
			return cosReply(sess, cos.OpCOSNameAck, cos.ErrPetNameTaken)
		}
		return cosReply(sess, cos.OpCOSNameAck, 1)
	}
	cosWorld.mu.Lock()
	o.rec.Name = name
	cosWorld.mu.Unlock()
	bumpPlayerState(owner)
	// To the owner and the area around the pet (s:FUN_004fb610): one
	// delivery here reaches both.
	sendAboutCOS(o, cos.OpCOSUpdate, cos.NameUpdate(o.uid, name))
	return nil
}

// handleCOSSetting is 0x7420 (s:0x511d10 -> FUN_004fadc0): kind 1 a growth
// pet's AI mode, kind 2 an ability pet's pickup flags. The reply is 0xB420
// {1, u32 uid, u8 kind, u32 value} or {2, u16 code}.
func handleCOSSetting(ctx context.Context, sess *gateway.Session, owner int64, data []byte) error {
	if len(data) < 9 {
		return cosReply(sess, cos.OpCOSSettingAck, 2)
	}
	uid := binary.LittleEndian.Uint32(data)
	kind := data[4]
	value := binary.LittleEndian.Uint32(data[5:])
	o := cosWorld.ownedOf(owner, uid)
	if o == nil {
		return cosReply(sess, cos.OpCOSSettingAck, 2)
	}
	cosWorld.mu.Lock()
	ok := (kind == 1 && o.kind == cos.KindGrowth) || (kind == 2 && o.kind == cos.KindAbility)
	if ok {
		o.rec.PetOption = value
	}
	rec := o.rec
	cosWorld.mu.Unlock()
	if !ok {
		return cosReply(sess, cos.OpCOSSettingAck, 3)
	}
	if d := cosWorld.depsNow(); d.store != nil {
		_ = d.store.Save(ctx, rec)
	}
	out := binary.LittleEndian.AppendUint32([]byte{1}, uid)
	out = append(out, kind)
	out = binary.LittleEndian.AppendUint32(out, value)
	return sess.Send(&proto.Packet{Opcode: cos.OpCOSSettingAck, Data: out})
}
