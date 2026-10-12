package session

// The skill action block (round 785): retail's 0xB070/0xB071 tail -- the
// action's target, its flags, the per-target per-hit damage block and the
// caster's move -- carried byte for byte as a suffix on OpAttackResult and
// OpSkillCast. docs/protocol/skill_hit_block.md has the READ layout
// (server writer FUN_0059e8f0 / FUN_00585730 / FUN_005856d0 / FUN_005855f0;
// client reader FUN_00a54be0 / FUN_00a548e0 / FUN_00a55e00) and the OURS
// framing (the 0xAB marker and the trailing kinds array).

import (
	"encoding/binary"
	"errors"
	"math"

	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// actionBlockMarker opens an ActionBlock (OURS, version 1).
const actionBlockMarker byte = 0xAB

// The action flags (ctx+0x4c, READ).
const (
	ActionFlagDamage   uint8 = 0x01 // a damage block follows
	ActionFlagSnap     uint8 = 0x02 // 'tel2': the caster is put at the point
	ActionFlagMove     uint8 = 0x08 // 'tele'/'tel3': the caster slides to the point
	actionFlagMoveMask uint8 = ActionFlagSnap | ActionFlagMove
)

// The hit kinds (hit+5 & 0x7f, READ in Combat_ResolveDamage 0x58e5f0).
const (
	HitKindDamage    uint8 = 0
	HitKindBlocked   uint8 = 2
	HitKindKnockdown uint8 = 4 // "ko" (+0x23c), motion state 8
	HitKindKnockback uint8 = 5 // "kb" (+0x254), motion state 16
	HitKindWall      uint8 = 7
	HitKindAbsorbed  uint8 = 8
	// HitDied is bit 0x80: this hit killed the target (or broke the wall).
	HitDied uint8 = 0x80
)

// The hit flags byte (hit+6, READ): 1 an ordinary hit, 2 a critical.
const (
	HitFlagNormal   uint8 = 1
	HitFlagCritical uint8 = 2
)

// The target kinds of the OURS trailing array.
const (
	ActionTargetCharacter uint8 = 0
	ActionTargetMonster   uint8 = 1
)

// ActionHit is one hit record.
type ActionHit struct {
	Kind   uint8 // HitKind*, with HitDied OR'd in on the killing hit
	Flags  uint8 // HitFlag*
	Damage uint32
	// Status is the abnormal-state bits this hit inflicted
	// (statuseffect.MaskForSlot), 0 for none.
	Status uint32
	// Moved is the target's new position for kind 4/5, as Region and the
	// truncated region-local X, Y, Z.
	Region  uint16
	X, Y, Z int32
	// WallHP / WallMax are a kind-7 entry's.
	WallHP, WallMax uint16
}

// ActionTarget is one target and its hits (one per the block's hit count).
type ActionTarget struct {
	UID  uint32
	Kind uint8 // ActionTarget*
	Hits []ActionHit
}

// ActionBlock is the whole tail.
type ActionBlock struct {
	Target     uint32 // the action's target uid, 0 for none
	TargetKind uint8
	Flags      uint8
	HitCount   uint8
	Targets    []ActionTarget
	// The move (flags 2 or 8): the region and the truncated landing.
	MoveRegion          uint16
	MoveX, MoveY, MoveZ int32
}

// encode appends the block (marker included) to out.
func (b *ActionBlock) encode(out []byte) []byte {
	le := binary.LittleEndian
	out = append(out, actionBlockMarker)
	out = le.AppendUint32(out, b.Target)
	flags := b.Flags
	if len(b.Targets) > 0 {
		flags |= ActionFlagDamage
	}
	out = append(out, flags)
	if flags&ActionFlagDamage != 0 {
		hc := b.HitCount
		if hc == 0 {
			hc = 1
		}
		out = append(out, hc, uint8(len(b.Targets)))
		for _, t := range b.Targets {
			out = le.AppendUint32(out, t.UID)
			for i := 0; i < int(hc); i++ {
				var h ActionHit
				if i < len(t.Hits) {
					h = t.Hits[i]
				} else {
					h = ActionHit{Kind: HitKindDamage, Flags: HitFlagNormal}
				}
				out = h.encode(out)
			}
		}
	}
	if flags&actionFlagMoveMask != 0 {
		out = le.AppendUint16(out, b.MoveRegion)
		out = le.AppendUint32(out, uint32(b.MoveX))
		out = le.AppendUint32(out, uint32(b.MoveY))
		out = le.AppendUint32(out, uint32(b.MoveZ))
	}
	if flags&ActionFlagDamage != 0 {
		for _, t := range b.Targets {
			out = append(out, t.Kind)
		}
	}
	return append(out, b.TargetKind)
}

func (h ActionHit) encode(out []byte) []byte {
	le := binary.LittleEndian
	out = append(out, h.Kind)
	word := h.Damage<<8 | uint32(h.Flags)
	switch h.Kind & 0x7f {
	case HitKindDamage, HitKindKnockback, HitKindKnockdown:
		out = le.AppendUint32(out, word)
		out = le.AppendUint32(out, h.Status)
		if k := h.Kind & 0x7f; k == HitKindKnockback || k == HitKindKnockdown {
			out = le.AppendUint16(out, h.Region)
			out = le.AppendUint32(out, uint32(h.X))
			out = le.AppendUint32(out, uint32(h.Y))
			out = le.AppendUint32(out, uint32(h.Z))
		}
	case HitKindWall:
		out = le.AppendUint32(out, word)
		out = le.AppendUint16(out, h.WallHP)
		out = le.AppendUint16(out, h.WallMax)
	}
	return out
}

var errActionBlock = errors.New("session: malformed action block")

// DecodeActionBlock reads a block at the start of b (its marker included)
// and returns it with the bytes after it.
func DecodeActionBlock(b []byte) (*ActionBlock, []byte, error) {
	le := binary.LittleEndian
	if len(b) < 6 || b[0] != actionBlockMarker {
		return nil, b, errActionBlock
	}
	out := &ActionBlock{Target: le.Uint32(b[1:]), Flags: b[5]}
	b = b[6:]
	if out.Flags&ActionFlagDamage != 0 {
		if len(b) < 2 {
			return nil, nil, errActionBlock
		}
		out.HitCount = b[0]
		n := int(b[1])
		b = b[2:]
		for t := 0; t < n; t++ {
			if len(b) < 4 {
				return nil, nil, errActionBlock
			}
			tg := ActionTarget{UID: le.Uint32(b)}
			b = b[4:]
			for i := 0; i < int(out.HitCount); i++ {
				if len(b) < 1 {
					return nil, nil, errActionBlock
				}
				h := ActionHit{Kind: b[0]}
				b = b[1:]
				switch h.Kind & 0x7f {
				case HitKindDamage, HitKindKnockback, HitKindKnockdown:
					if len(b) < 8 {
						return nil, nil, errActionBlock
					}
					w := le.Uint32(b)
					h.Flags, h.Damage, h.Status = uint8(w), w>>8, le.Uint32(b[4:])
					b = b[8:]
					if k := h.Kind & 0x7f; k == HitKindKnockback || k == HitKindKnockdown {
						if len(b) < 14 {
							return nil, nil, errActionBlock
						}
						h.Region = le.Uint16(b)
						h.X, h.Y, h.Z = int32(le.Uint32(b[2:])), int32(le.Uint32(b[6:])), int32(le.Uint32(b[10:]))
						b = b[14:]
					}
				case HitKindWall:
					if len(b) < 8 {
						return nil, nil, errActionBlock
					}
					w := le.Uint32(b)
					h.Flags, h.Damage = uint8(w), w>>8
					h.WallHP, h.WallMax = le.Uint16(b[4:]), le.Uint16(b[6:])
					b = b[8:]
				}
				tg.Hits = append(tg.Hits, h)
			}
			out.Targets = append(out.Targets, tg)
		}
	}
	if out.Flags&actionFlagMoveMask != 0 {
		if len(b) < 14 {
			return nil, nil, errActionBlock
		}
		out.MoveRegion = le.Uint16(b)
		out.MoveX, out.MoveY, out.MoveZ = int32(le.Uint32(b[2:])), int32(le.Uint32(b[6:])), int32(le.Uint32(b[10:]))
		b = b[14:]
	}
	if out.Flags&ActionFlagDamage != 0 {
		if len(b) < len(out.Targets) {
			return nil, nil, errActionBlock
		}
		for i := range out.Targets {
			out.Targets[i].Kind = b[i]
		}
		b = b[len(out.Targets):]
	}
	if len(b) < 1 {
		return nil, nil, errActionBlock
	}
	out.TargetKind = b[0]
	return out, b[1:], nil
}

// regionPoint is a position as retail's (region, truncated local x, y, z):
// _ftol2 truncates toward zero (0x5866c1..0x5866ea, READ).
func regionPoint(zone string, pos world.Position) (uint16, int32, int32, int32) {
	region, lx, lz := regionLocalOf(zone, pos)
	return region, int32(math.Trunc(lx)), int32(math.Trunc(pos.Y)), int32(math.Trunc(lz))
}
