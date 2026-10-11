package teleport

import "math"

// The interaction range of a teleport (round 642's review), READ from
// GObjPC::IsWithinInteractionRange (0x4a8e10), which GObjPC::HandleTeleportUse
// (0x513590) calls right after its "already teleporting" test and refuses with
// whatever it returns other than 1:
//
//  1. The target's type is tested against a mask chosen by whether it is an
//     NPC: 0x146 when the gate object answers IGObj::IsNPCNPC (vslot 9,
//     +0x24), else 0x30 (HandleTeleportUse, `(-(iVar4 != 0) & 0x116) + 0x30`).
//     FUN_004a8d90 compares the object's TypeID bit fields with the mask's:
//     0x146 is TypeID1 1, TypeID2 2, TypeID3 2 (a character, an NPC, an
//     NPCNPC -- NPC_CH_FERRY's characterdata columns 9-11 read 1, 2, 2), 0x30
//     is TypeID1 4, TypeID2 1 (a structure). A mismatch returns 3.
//  2. The two objects' regions must be the same kind (field or dungeon, bit
//  15. and, for field regions, within one of each other on both bytes
//     (FUN_00430ce0: |dx| < 2 and |dy| < 2). Otherwise 3.
//  3. The distance limit is picked by the target's class, in this order of
//     vtable tests: IsPC 600.0 (.rdata 0xb46198), IsNPCNPC 300.0 (0xb45c40),
//     IsMonster 500.0 (0xb46168), IsCOS 1500.0 (0xb46194), IsStruct 800.0
//     (0xb46190), IsItem 10.0 (0xb45b44), IsPet 500.0 (0xb46168), else 320.0
//     (0xb460dc) -- the floats read out of SR_GameServer.exe's .rdata.
//  4. The offset is FUN_00430ba0's: in field regions each axis is the local
//     difference plus 1920.0 (.rdata 0xb45ad0, a double) times the region-byte
//     difference -- the low byte (region y) on x, the high byte (region x) on
//     z -- and y is the plain height difference. The length
//     sqrt(dx*dx + dy*dy + dz*dz) must be <= the limit (`fVar9 <= limit`),
//     else 4.
//
// Codes 3 and 4 go back in the 0xb05a reply as they are. The client's
// category-0xd message table shows 4 as UIIT_MSG_INTERACTION_FAIL_TOO_FAR
// (0x7ba03b) and 3 as nothing (the default, 0x7b913a).
const (
	// ErrInteractionTarget is IsWithinInteractionRange's 3: the target is not
	// of the gate's type, or not in the requester's region or a neighbour.
	ErrInteractionTarget = 3
	// ErrTooFar is its 4: the target is beyond its class's distance.
	ErrTooFar = 4 // category 0xd: UIIT_MSG_INTERACTION_FAIL_TOO_FAR

	// RangeNPC is the limit for an IsNPCNPC target (a ferry seller, a gate
	// soldier): 300.0 at .rdata 0xb45c40.
	RangeNPC = 300.0
	// RangeStructure is the limit for an IsStruct target (a Dimensional
	// Gate): 800.0 at .rdata 0xb46190.
	RangeStructure = 800.0
)

// Place is where something stands: its region id and region-local x/y/z, as
// the tables give them.
type Place struct {
	Region  int
	X, Y, Z float64
}

// Reach is IsWithinInteractionRange's region and distance tests (steps 2 to 4
// above) for a requester at `from` and a target at `to` with limit `limit`: 1
// when within reach, ErrInteractionTarget when the regions are of different
// kinds or more than one apart, ErrTooFar when farther than the limit.
//
// OURS, disclosed: the height term is dropped (horizontal=true). OpenSRO's
// server does not know a player's height reliably -- an arrival and a zone
// entry hold y = 0 until the client's first move, and the client sends none
// after it lands a teleport (World3D._land_teleport_arrival) -- so the 3-D
// length would refuse a player standing next to an airship seller at height
// 2,105. A horizontal distance is never longer than the 3-D one, so this
// allows at most what retail allows plus the height difference.
func Reach(from, to Place, limit float64, horizontal bool) int {
	fd, td := from.Region < 0 || from.Region&0x8000 != 0, to.Region < 0 || to.Region&0x8000 != 0
	if fd != td {
		return ErrInteractionTarget
	}
	var dx, dz float64
	if fd {
		// Two different dungeons share no space (OURS, round 773: the region
		// test FUN_00430ce0 was read for field regions only; a rid spelt
		// signed and unsigned is one dungeon).
		if from.Region&0xFFFF != to.Region&0xFFFF {
			return ErrInteractionTarget
		}
		dx, dz = to.X-from.X, to.Z-from.Z
	} else {
		fy, ty := from.Region&0xFF, to.Region&0xFF
		fx, tx := (from.Region>>8)&0xFF, (to.Region>>8)&0xFF
		if abs(ty-fy) >= 2 || abs(tx-fx) >= 2 {
			return ErrInteractionTarget
		}
		dx = to.X + float64(ty-fy)*1920.0 - from.X
		dz = to.Z + float64(tx-fx)*1920.0 - from.Z
	}
	dy := to.Y - from.Y
	if horizontal {
		dy = 0
	}
	if math.Sqrt(dx*dx+dy*dy+dz*dz) <= limit {
		return 1
	}
	return ErrTooFar
}

func abs(v int) int {
	if v < 0 {
		return -v
	}
	return v
}
