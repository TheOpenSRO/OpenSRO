package session

import (
	"context"
	"encoding/binary"
	"errors"
	"log/slog"
	"math"
	"math/rand"
	"os"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/cos"
	"github.com/OpenSRO/OpenSRO/server/internal/grounditem"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/species"
	"github.com/OpenSRO/OpenSRO/server/internal/txn"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// What a COS does on its own (round 795; docs/protocol/pets.md, "Round
// 795", READ unless marked):
//
//   - It follows its owner: IDLE turns to FOLLOW once the owner is 65.0 away
//     (s:FUN_005485b0, 0xb46298), and FOLLOW runs to a point selfBC +
//     ownerBC + rand()%10+1 around the owner and settles once within selfBC +
//     50.0 (s:FUN_00549ac0, 0xb46288). A rider's COS is where its rider is.
//   - An ability pet picks up what its owner's client points it at (0x70C5
//     command 8: the client chooses the nearest eligible item within 500,
//     c:0x8af7f0): it runs to the item, takes it within 10.0
//     (CAIState_PICKITEM s:0x55ac20, 0xb45b44), gives up past 1000.0, and
//     stands 3 s.
//   - A growth pet attacks what its owner's client names (0x70C5 command 2,
//     sent on the owner's own offensive cast in attack mode) with its row's
//     col-83 skill, until the target dies or it is told to follow.
//   - Hunger (growth pets), regeneration, and an ability pet's rent run on
//     their own clocks (cos.HungerPerSecond, cos.RegenPeriod,
//     cos.RentCheckPeriod).
//
// OURS, disclosed: the tick (cosTick); a pet that falls more than
// cosWarpRange behind is put back beside its owner (retail has no such
// leash that was found, OPEN); monsters do not target a COS (their AI knows
// characters only): a pet's blows are booked to its owner, whom the monster
// then answers.

const (
	cosTick       = 100 * time.Millisecond
	cosFollowFar  = 65.0
	cosFollowNear = 50.0
	// ownerBCRadius is every player body's col 50 (MEASURED: 4 on all 77
	// CHAR_ rows).
	ownerBCRadius = 4.0
	cosPickReach  = 10.0
	cosPickGiveUp = 1000.0
	cosPickDwell  = 3 * time.Second
	cosWarpRange  = 400.0
	// cosReaim is how far a leg's end may drift from where the pet wants to
	// be before it is sent a new one (OURS: retail re-aims on its 100 ms
	// FOLLOW timer with a fresh random point each time).
	cosReaim = 20.0
	// cosCorpse is how long a dead pet lies before it leaves (OURS: the
	// path that clears a dead COS was not found, OPEN).
	cosCorpse = 5 * time.Second
)

// cosTrace logs each target decision (OPENSRO_COS_TRACE=1, OURS: QA).
var cosTrace = os.Getenv("OPENSRO_COS_TRACE") != ""

// RunCOS steps every COS until ctx is done.
func RunCOS(ctx context.Context, logger *slog.Logger) {
	t := time.NewTicker(cosTick)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-t.C:
			func() {
				defer func() {
					if r := recover(); r != nil && logger != nil {
						logger.Error("cos: tick panicked", "panic", r)
					}
				}()
				cosWorld.tick(ctx, now)
			}()
		}
	}
}

// cosAction is what one COS's tick decided, carried out after the lock.
type cosAction struct {
	o        *cosObj
	moveTo   *world.Position
	stop     bool
	warp     bool
	hgp      int // >= 0: the gauge to tell the owner
	starve   bool
	hp       int // >= 0: the HP to tell the owner
	expired  bool
	pickNow  bool
	pickFail uint16
	pickItem uint32
	swing    bool
	target   int64
	dropTgt  bool
	corpse   bool
}

func (w *cosRuntime) tick(ctx context.Context, now time.Time) {
	d := w.depsNow()
	if !d.enabled || d.hub == nil {
		return
	}
	cd, _ := skillDeps()
	var acts []cosAction
	w.mu.Lock()
	objs := make([]*cosObj, 0, len(w.byUID))
	for _, o := range w.byUID {
		objs = append(objs, o)
	}
	w.mu.Unlock()
	for _, o := range objs {
		owner, ok := d.hub.EntityByCharacterID(o.owner)
		if !ok {
			continue
		}
		ownerPos := owner.Pos
		if owner.Move != nil {
			ownerPos, _ = owner.Move.At(now)
		}
		a := cosAction{o: o, hgp: -1, hp: -1}
		w.mu.Lock()
		dt := now.Sub(o.lastTick).Seconds()
		o.lastTick = now
		if o.dead {
			if now.Sub(o.legStart) >= cosCorpse {
				a.corpse = true
			}
			w.mu.Unlock()
			acts = append(acts, a)
			continue
		}
		if o.ridden {
			o.pos, o.heading, o.zone, o.moving = ownerPos, owner.Heading, owner.Zone, false
		} else {
			o.settle(now)
		}
		// Hunger, a growth pet's (s:0x4d5e00).
		if o.kind == cos.KindGrowth && dt > 0 {
			o.hgpAcc += cos.HungerPerSecond() * dt
			if o.hgpAcc >= 1 {
				n := int(o.hgpAcc)
				o.hgpAcc -= float64(n)
				old := o.rec.HGP
				if n >= old {
					o.rec.HGP = 0
					a.starve = true
				} else {
					o.rec.HGP -= n
					if cos.HungerCrossedTen(old, o.rec.HGP) {
						a.hgp = o.rec.HGP
					}
				}
			}
		}
		// Regeneration (slot 362 on a 4 s timer), standing or sitting.
		if !now.Before(o.regenAt) {
			o.regenAt = now.Add(cos.RegenPeriod)
			if max := o.row.MaxHP; o.rec.HP < max && !o.moving {
				o.rec.HP = min(max, o.rec.HP+cos.RegenAmount(max))
				a.hp = o.rec.HP
			}
		}
		// An ability pet's rent (slot 368 every 30 s).
		if o.kind == cos.KindAbility && !now.Before(o.rentAt) {
			o.rentAt = now.Add(cos.RentCheckPeriod)
			if cos.RentSecondsLeft(o.rec.RentEnd, now) < 1 {
				a.expired = true
			}
		}
		if o.ridden || a.starve || a.expired {
			w.mu.Unlock()
			acts = append(acts, a)
			continue
		}
		pos := o.at(now)
		if o.zone != owner.Zone || cosDistance(pos, ownerPos) > cosWarpRange {
			a.warp = true
			o.zone, o.pos, o.moving = owner.Zone, ownerPos, false
			w.mu.Unlock()
			acts = append(acts, a)
			continue
		}
		switch {
		case o.pick != 0:
			a.pickItem = uint32(o.pick)
			it, ok := cosGroundItem(cd.ground, o.pick)
			if !ok {
				a.pickFail, o.pick = cosPickBusy, 0
				break
			}
			ip := world.Position{X: float64(it.X), Y: float64(it.Y), Z: float64(it.Z)}
			dist := cosDistance(pos, ip)
			switch {
			case dist <= cosPickReach:
				a.pickNow = true
				o.moving, o.pos = false, pos
			case dist > cosPickGiveUp:
				a.pickFail, o.pick = cosPickBusy, 0
			case !o.moving || cosDistance(o.to, ip) > 1:
				a.moveTo = &ip
			}
		case o.target != 0:
			m, ok := cd.monsters.Get(o.target)
			if cosTrace {
				d.logger.Info("cos: target", "cos", o.uid, "monster", o.target, "found", ok, "hp", m.HP, "zone", m.Zone, "own_zone", o.zone,
					"dist", cosDistance(pos, world.Position{X: m.X, Y: m.Y, Z: m.Z}), "reach", float64(o.row.BCRadius+m.BCRadius)+cosAttackRange(o.row))
			}
			if !ok || m.HP <= 0 || m.Zone != o.zone {
				a.dropTgt, o.target = true, 0
				break
			}
			mp := world.Position{X: m.X, Y: m.Y, Z: m.Z}
			reach := float64(o.row.BCRadius+m.BCRadius) + cosAttackRange(o.row)
			if cosDistance(pos, mp) <= reach {
				if o.moving {
					o.moving, o.pos = false, pos
					a.stop = true
				}
				if !now.Before(o.nextSwing) {
					a.swing, a.target = true, o.target
					o.nextSwing = now.Add(cosAttackReuse(o.row))
				}
			} else if !o.moving || cosDistance(o.to, mp) > reach {
				a.moveTo = &mp
			}
		default:
			d := cosDistance(pos, ownerPos)
			if (!o.moving && d >= cosFollowFar) || (o.moving && cosDistance(o.to, ownerPos) > cosReaim+float64(o.row.BCRadius)) {
				ang := rand.Float64() * 2 * math.Pi
				r := float64(o.row.BCRadius) + ownerBCRadius + float64(rand.Intn(10)+1)
				p := world.Position{X: ownerPos.X + r*math.Cos(ang), Y: ownerPos.Y, Z: ownerPos.Z + r*math.Sin(ang)}
				if d > float64(o.row.BCRadius)+cosFollowNear || o.moving {
					a.moveTo = &p
				}
			}
		}
		if a.moveTo != nil {
			o.from, o.to, o.legStart, o.legSpeed, o.moving = pos, *a.moveTo, now, o.row.RunSpeed, true
			o.pos = pos
			o.heading = world.HeadingToward(o.heading, a.moveTo.X-pos.X, a.moveTo.Z-pos.Z)
		}
		w.mu.Unlock()
		acts = append(acts, a)
	}
	for _, a := range acts {
		w.act(ctx, cd, a, now)
	}
}

// act carries a tick's decision out.
func (w *cosRuntime) act(ctx context.Context, cd combatDeps, a cosAction, now time.Time) {
	o := a.o
	switch {
	case a.corpse:
		cosVanish(o)
		w.remove(o)
		return
	case a.starve:
		// HGP 0: slot 219 (INFERRED: the pet is put away, not killed).
		sendToCOSOwner(o, cos.OpCOSUpdate, cos.HGPUpdate(o.uid, 0))
		releaseCOS(ctx, o, releaseStore)
		return
	case a.expired:
		releaseCOS(ctx, o, releaseDead)
		return
	}
	if a.hgp >= 0 {
		sendToCOSOwner(o, cos.OpCOSUpdate, cos.HGPUpdate(o.uid, a.hgp))
		cosSave(ctx, o)
	}
	if a.hp >= 0 {
		sendCOSHP(o, a.hp)
	}
	if a.warp {
		sendCOSStop(o)
	}
	if a.stop {
		sendCOSStop(o)
	}
	if a.moveTo != nil {
		sendCOSMove(o, *a.moveTo)
	}
	if a.pickFail != 0 {
		sendToCOSOwner(o, cos.OpCOSCommandAck, pickFail(o.uid, a.pickItem, a.pickFail))
	}
	if a.pickNow {
		cosPick(ctx, cd, o, a.pickItem, now)
	}
	if a.swing {
		cosStrike(ctx, cd, o, a.target)
	}
}

// cosSave writes o's record.
func cosSave(ctx context.Context, o *cosObj) {
	d := cosWorld.depsNow()
	if d.store == nil {
		return
	}
	cosWorld.mu.Lock()
	rec := o.rec
	cosWorld.mu.Unlock()
	_ = d.store.Save(ctx, rec)
}

// sendCOSMove is the 0xB021 of o's leg to dest, to everyone who holds its
// owner.
func sendCOSMove(o *cosObj, dest world.Position) {
	cosWorld.mu.Lock()
	zone, src := o.zone, o.from
	cosWorld.mu.Unlock()
	region, lx, lz := regionLocalOf(zone, dest)
	m := proto.Movement{Kind: 1, Region: region}
	if region&proto.MovementRegionWorldBit != 0 {
		m.X, m.Y, m.Z = int32(lx), int32(dest.Y), int32(lz)
	} else {
		m.LocalX, m.LocalY, m.LocalZ = int16(lx), int16(dest.Y), int16(lz)
	}
	sr, sx, sz := regionLocalOf(zone, src)
	sendAboutCOS(o, proto.OpMovementResponse, encodeMoveEcho(o.uid, m.Encode(), sr, src, sx, sz))
}

// sendCOSStop is the 0xB023 of o where it stands.
func sendCOSStop(o *cosObj) {
	cosWorld.mu.Lock()
	e := world.Entity{CharacterID: int64(o.uid), Zone: o.zone, Pos: o.pos, Heading: o.heading}
	cosWorld.mu.Unlock()
	region, lx, lz := regionLocalOf(e.Zone, e.Pos)
	out := binary.LittleEndian.AppendUint32(nil, o.uid)
	out = binary.LittleEndian.AppendUint16(out, region)
	out = binary.LittleEndian.AppendUint32(out, math.Float32bits(float32(lx)))
	out = binary.LittleEndian.AppendUint32(out, math.Float32bits(float32(e.Pos.Y)))
	out = binary.LittleEndian.AppendUint32(out, math.Float32bits(float32(lz)))
	out = binary.LittleEndian.AppendUint16(out, proto.EncodeMovementAngle(world.WireAngle(e.Heading)))
	sendAboutCOS(o, OpMovementStop, out)
}

// OwnerCOS is OpObjectStatus's owner kind for a COS (round 795, OURS beside
// OwnerCharacter and OwnerMonster): the id is its u32 uid.
const OwnerCOS uint8 = 2

// sendCOSHP is a COS's HP, retail 0x3057's flag 1 (c:0x8a9e30 writes it to
// the COS record +8 whether or not the COS is in view), under OpenSRO's
// head: u8 OwnerCOS, i64 uid, u16 0, u8 1, u32 HP.
func sendCOSHP(o *cosObj, hp int) {
	out := []byte{OwnerCOS}
	out = binary.LittleEndian.AppendUint64(out, uint64(o.uid))
	out = binary.LittleEndian.AppendUint16(out, 0)
	out = append(out, 1)
	out = binary.LittleEndian.AppendUint32(out, uint32(max(0, hp)))
	sendAboutCOS(o, OpObjectStatus, out)
}

// cosGroundItem is the ground item id, ok false when it is gone.
func cosGroundItem(ground *grounditem.Hub, id int64) (grounditem.Item, bool) {
	if ground == nil {
		return grounditem.Item{}, false
	}
	return ground.Get(id)
}

// cosPick is the pet's take of item (GObjPC::FUN_004d4f60 type 0x11 ->
// FUN_004d5510's routing, READ): gold to the owner's purse; a quest item, an
// untradeable or an undroppable one to the owner's bag; anything else to the
// pet's own bag. The owner is the picker the ground's rules ask about.
func cosPick(ctx context.Context, cd combatDeps, o *cosObj, itemUID uint32, now time.Time) {
	cosWorld.mu.Lock()
	o.pick = 0
	o.nextSwing = now.Add(cosPickDwell)
	pos, owner, recID := o.pos, o.owner, o.rec.ID
	cosWorld.mu.Unlock()
	fail := func(code uint16) {
		sendToCOSOwner(o, cos.OpCOSCommandAck, pickFail(o.uid, itemUID, code))
	}
	d := cosWorld.depsNow()
	if cd.ground == nil || d.bags == nil {
		fail(cosPickBusy)
		return
	}
	probe, ok := cd.ground.Get(int64(itemUID))
	if !ok {
		fail(cosPickBusy)
		return
	}
	// The owner's ground rules from where the item lies (the 10-unit reach
	// was the pet's own).
	it, code := cd.ground.PickCheck(int64(itemUID), owner, probe.X, probe.Y, probe.Z, samePartyFunc(cd.parties))
	if code != 0 {
		fail(uint16(code))
		return
	}
	toOwner := it.Gold || it.OwnerOnly()
	if !toOwner {
		if ref, err := d.items.GetItem(ctx, it.ItemID); err != nil || ref == nil || !ref.CanTrade || !ref.CanDrop {
			toOwner = true
		}
	}
	if !it.Gold && it.Instance == nil {
		if inst, ok := freshDropInstance(ctx, it.ItemID); ok {
			it.Instance = &inst
		}
	}
	key := pickupLedgerKey(it)
	var err error
	if toOwner {
		var shares []goldShare
		if it.Gold {
			shares = []goldShare{{owner, int64(it.Quantity)}}
		}
		err = applyPickup(ctx, txn.For(cd.chars, cd.inv), cd.chars, cd.inv, it, key, owner, shares)
	} else {
		err = applyPickup(ctx, txn.For(cd.chars, d.bags), cd.chars, d.bags, it, key, recID, nil)
	}
	if err != nil {
		cd.ground.Release(it.ID)
		switch {
		case errors.Is(err, inventory.ErrNoRoom) && toOwner:
			fail(0x18b5) // COSPETERR_CANT_PICKITEM2: the owner's bag is full
		case errors.Is(err, inventory.ErrNoRoom):
			fail(0x18b4) // COSPETERR_CANT_PICKITEM1: the pet's bag is full
		default:
			fail(cosPickBusy)
		}
		return
	}
	cd.ground.Remove(it.ID)
	e, inWorld := cosOwnerEntity(owner)
	if toOwner {
		if inWorld && e.Session != nil {
			if it.Gold {
				tellGold(ctx, cd.chars, cd.hub, owner, false)
			}
			_ = e.Session.Send(&proto.Packet{Opcode: OpPickUpResult, Data: (&PickUpResult{GroundItemID: it.ID,
				ItemID: it.ItemID, Quantity: it.Quantity, Gold: it.Gold}).Encode()})
		}
		sendToCOSOwner(o, cos.OpCOSCommandAck, pickOK(o.uid, itemUID))
	} else if slot, rec, ok := cosBagSlotOf(ctx, recID, it.ItemID); ok {
		// 0xB034 type 0x11: u32 pet, u8 slot, the item record (c:0x87bc36).
		out := []byte{itemOpOK, 0x11}
		out = binary.LittleEndian.AppendUint32(out, o.uid)
		out = append(out, byte(slot))
		out = append(out, rec...)
		sendToCOSOwner(o, OpItemMoveResult, out)
	}
	if inWorld {
		broadcastPickUpMotion(cd.hub, e.Zone, int64(o.uid), pos.X, pos.Z, it)
	}
	broadcastGroundRemoval(cd.hub, it, owner)
}

// cosBagSlotOf is where itemID now sits in COS cosID's bag (the last slot
// holding it), with its record.
func cosBagSlotOf(ctx context.Context, cosID, itemID int64) (int, []byte, bool) {
	for _, di := range cosBagItems(ctx, cosID) {
		if int64(binary.LittleEndian.Uint32(di.Record[4:])) == itemID {
			return int(di.Slot), di.Record, true
		}
	}
	return -1, nil, false
}

// cosAttack is the row's col-83 skill as the monsters' table reads it.
func cosAttack(row species.Row) (combat.MonsterSkill, bool) {
	l := cosWorld.depsNow().skillLookup
	if l == nil {
		return combat.MonsterSkill{}, false
	}
	a := row.Attacks(l)
	return a.Primary, a.HasPrimary
}

// cosAttackRange is the reach of the row's attack (its skill's range; 10
// without one, OURS).
func cosAttackRange(row species.Row) float64 {
	if s, ok := cosAttack(row); ok && s.Range > 0 {
		return float64(s.Range)
	}
	return 10
}

// cosAttackReuse is the row's attack cadence (its skill's reuse; 2 s
// without one, OURS).
func cosAttackReuse(row species.Row) time.Duration {
	if s, ok := cosAttack(row); ok && s.ReuseMs > 0 {
		return time.Duration(s.ReuseMs) * time.Millisecond
	}
	return 2 * time.Second
}

// cosStrike is a growth pet's blow on monster id: its skill's damage range,
// halved below 30 % HGP (s:0x4d60a0's 50 on the damage params), resolved
// against the monster's defence, booked to the owner.
func cosStrike(ctx context.Context, cd combatDeps, o *cosObj, id int64) {
	if cd.monsters == nil {
		return
	}
	m, ok := cd.monsters.Get(id)
	if !ok || m.HP <= 0 {
		return
	}
	cosWorld.mu.Lock()
	row, owner, hgp, level := o.row, o.owner, o.rec.HGP, o.rec.Level
	cosWorld.mu.Unlock()
	lo, hi := 1, 1
	if s, ok := cosAttack(row); ok {
		lo, hi = s.AttMin, s.AttMax
	}
	if hi < lo {
		hi = lo
	}
	base := rollDamage(lo, hi)
	if hgp < cos.HGPLow {
		base /= 2
	}
	flat, pct := monsterDefence(m)
	blow := resolveBlow(base, pct, flat, row.Critical(), m.Block, level, m.Level, int64(o.uid), m.ID)
	dmg := blow.Damage
	if dmg <= 0 {
		return
	}
	updated, died, ok, watchers, hits := damageMonsterWatched(cd.hub, cd.monsters, id, owner, dmg)
	if !ok {
		return
	}
	if cosTrace {
		cosWorld.depsNow().logger.Info("cos: a pet struck", "cos", o.uid, "monster", id, "damage", dmg, "hp", updated.HP, "died", died)
	}
	if !died {
		noteStruck(cd.monsters, id, owner)
		msg := &MonsterDamaged{MonsterID: id, Damage: int32(dmg), RemainingHP: int32(updated.HP)}
		for _, e := range watchers {
			sendMonsterPush(e.Session, &proto.Packet{Opcode: OpMonsterDamaged, Data: msg.Encode()})
		}
		return
	}
	cosWorld.mu.Lock()
	o.target = 0
	cosWorld.mu.Unlock()
	noteMonsterKilled(cd.hub, cd.parties, hits, updated)
	statusFX.forgetMonster(id)
	if err := statusFX.settleKill(ctx, cd, statusKill{monster: m, killer: owner, damage: dmg, updated: updated, hits: hits}, watchers); err != nil {
		cosWorld.depsNow().logger.Warn("cos: a pet's kill did not settle", "cos", o.uid, "monster", id, "err", err)
		return
	}
	if cosTrace {
		cosWorld.depsNow().logger.Info("cos: a pet killed", "cos", o.uid, "monster", id, "owner", owner, "watchers", len(watchers))
	}
}
