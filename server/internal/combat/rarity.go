package combat

// A second thing rank 7 does, read 2026-09-19 (round 236): when a monster whose
// GetMonsterClass (slot 75, the low nibble of +0x1cd8) is 7 dies,
// GObjPC::FUN_009348f0 drops THREE extra piles of ITEM_ETC_GOLD_03, each the
// per-level gold roll (CRefDropGold: rand()%101 <= chance, then [min, max])
// times FOUR -- unless the species id is 10100 or 11000. No other rank takes
// that path, and no ordinary kill rolls that table (combat.RollGold's note).
// srrevamp spawns no rank-7 species today, so nothing applies it; it is
// recorded here so the rule is not re-derived when one is added.
//
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
// The x10 mode is READ, not inferred (2026-09-19): before the switch,
// PublishStats starts from 1000.0 (float at 0xb462ac) instead of 100.0 when
// vtable slot 192 answers 1. Slot 192 is GetMonsterType -- CGObjMob's override
// returns the HIGH nibble of the byte at this+0x1cd8, whose LOW nibble is
// GetMonsterClass (the rank above, slot 75) -- and IsPartySupportMonster
// (slot 193) is exactly `(byte & 0xf0) == 0x10`, i.e. MonsterType == 1. A
// party monster therefore carries ten times the HP percentage before its
// rank multiplies it (a party giant is x200). Nothing srrevamp spawns is a
// party monster today; the flag is carried so the first one will be right.
// The rank names are the ones combat.Monster.Rarity already documents from
// characterdata column 15.
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

// MonsterHPPercent is the whole percentage the engine publishes: the rank
// multiplier on a base of 100, or of 1000 for a party-support monster
// (MonsterType 1). Uniques (ranks 3 and 8) keep their row's HP either way.
func MonsterHPPercent(rarity int, partySupport bool) int {
	pct := RarityHPPercent(rarity)
	if partySupport && rarity != 3 && rarity != 8 {
		pct *= 10
	}
	return pct
}

// ScaleHPForRarity applies RarityHPPercent to a species' authored max HP the
// way the engine's percentage param scales the published stat.
func ScaleHPForRarity(maxHP, rarity int) int {
	return maxHP * RarityHPPercent(rarity) / 100
}

// ScaleHPForMonster is ScaleHPForRarity with the party-support x10 folded in.
func ScaleHPForMonster(maxHP, rarity int, partySupport bool) int {
	return maxHP * MonsterHPPercent(rarity, partySupport) / 100
}
