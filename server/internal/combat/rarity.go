package combat

// RarityHPPercent is the engine's HP scale for a monster's rank, as a percent.
//
// Read from SR_GameServer.exe, CGObjMob::PublishStats (0x004c19f0, vtable slot
// 346): after the species' own stats are published it sets ParamKeeper param 3
// -- the 'hp' slot of the recovered stat vocabulary -- to a percentage chosen
// by the rank the object reports through vtable slot 75:
//
//	fld DWORD [0xb45e10]   ; 100.0  (float -- the base, 100 %)
//	case 0:  x1            ; general
//	case 1:  +itself       ; champion   x2
//	case 6:  fmul [0xb45cf0] = 4.0    ; elite      x4
//	case 4:  fmul [0xb45ac8] = 20.0   ; giant      x20
//	case 7:  fmul [0xb45e58] = 30.0   ; rank 7     x30 (no client name recovered)
//	case 5:  fmul [0xb45af0] = 100.0  ; titan      x100
//	case 3, 8: return      ; uniques keep the HP their own row states
//	default: assert
//
// The multipliers are QWORD (double) constants read from .rdata and the two
// bases DWORD floats (fld DWORD at 0x4c19fe / 0x4c1a28) -- operand size
// checked on the asm, the trap that has bitten this project before. The
// client's target window applies the same x2/x4/x20/x100 to a special
// monster's displayed maximum (round 205), which is the display half of this
// rule.
//
// DISCLOSED, not applied: before the switch, an object answering 1 through
// vtable slot 192 starts from 1000.0 (float at 0xb462ac) instead of 100.0 --
// a x10 on top of the rank. Slot 193 is IsPartySupportMonster (round 203), so
// by adjacency 192 is most likely "is a party monster"; nothing srrevamp
// spawns carries that flag and no data here says which species do, so the
// x10 is recorded and not wired. The rank names are the ones
// combat.Monster.Rarity already documents from characterdata column 15.
func RarityHPPercent(rarity int) int {
	switch rarity {
	case 0:
		return 100
	case 1:
		return 200
	case 6:
		return 400
	case 4:
		return 2000
	case 7:
		return 3000
	case 5:
		return 10000
	case 3, 8:
		// The engine returns before publishing: a unique's authored HP stands.
		return 100
	default:
		// The engine asserts on any other rank; a row we cannot classify
		// keeps its authored HP rather than a guessed multiple.
		return 100
	}
}

// ScaleHPForRarity applies RarityHPPercent to a species' authored max HP the
// way the engine's percentage param scales the published stat.
func ScaleHPForRarity(maxHP, rarity int) int {
	return maxHP * RarityHPPercent(rarity) / 100
}
