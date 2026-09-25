package ai

import (
	"math"
	"math/rand"
)

// Target acquisition, the runtime's half (round 552): the pure rules
// session/monsterai.go's acquire runs behind cmd/server's -monster-aggro
// (SRREVAMP_MONSTER_AGGRO), OFF by default. The rule itself -- BCRadius plus
// the row's detection distance, the nearest player, no level term -- was read
// in round 257 (state.go, DetectionRadius, and docs/protocol/monster_ai.md,
// "Target acquisition"); what is below is the rest of what the scan needs and
// had not been carried: how often it runs, whether it runs at all, and the
// selector's own compare. Every address was re-read in /var/tmp/srv.asm for
// this round; the reading is in monster_ai.md, "Target acquisition: the
// runtime (round 552)".
//
// The four _RefTactics columns this reads are server-database only
// (monster_ai.md, "The _RefTactics row, read off its parser"), so each is an
// OWN-DESIGN stand-in, one constant, disclosed at the constant. Two of them
// are USER DECISIONS with no grounded value anywhere: whether a species is
// aggressive at all, and how far it sees.

// TacticsDetectionDistance stands in for column 6 (row +0x14), the detection
// distance in world units: the acquisition radius is BCRadius + this
// (ctx+0x15c, BindSkillsAndRanges 0x53fa23..0x53fa4f: `fild` the BCRadius,
// `fiadd DWORD [row+0x14]`, `fstp [ctx+0x15c]`), so 104..111 for the roster
// (BCRadius 4 for the Tomb Stone Ghost and the Earth Ghost, up to 11 for the
// Yeoha). OWN DESIGN and a user decision: the column is server-database only
// and no value for any species was read anywhere; 100 is the plan's
// recommendation. A zero here would install the no-op behaviour instead
// (FUN_00559000 at +0xf8) and no monster would ever notice anyone -- which is
// what the flag's OFF setting is for.
const TacticsDetectionDistance = 100

// TacticsAggressionMode stands in for column 7 (row +0x18), the aggression
// mode AI::CTactics::Init copies into ctx+0x168 (`mov al,[row+0x18]` 0x53f5be,
// `mov [ctx+0x168],al` 0x53f5c3) unless it is 2, when the byte is the roll
// below. AITactics_AcquireTarget scans only while that byte is 0 or 3
// (`test al,al; je` 0x54795e, `cmp al,0x3; jne` 0x547962). OWN DESIGN and a
// user decision: 0, every roster species aggressive, the plan's
// recommendation; the flag itself is the "none aggressive" setting. The
// column is server-database only.
const TacticsAggressionMode uint8 = 0

// TacticsAggressionPct stands in for column 8 (row +0x1c), the aggressive
// chance in percent under mode 2 (`idiv` by 100 at 0x53f5d6, `cmp edx,[row+
// 0x1c]; setge cl` 0x53f5db..0x53f5de). Not read under mode 0; kept at the
// constant so the roll is one call. OWN DESIGN; server-database only.
const TacticsAggressionPct = 0

// TacticsFlags stands in for column 42 (row +0x90), the flag word. The scan
// reads two things off it: bits 2 and 7 (TacticsFlagsFastScan) pick the fast
// timer, and bits 2, 7 and 8 widen the kinds the scan takes (players only
// under 0: `mov byte [esp+0x18],0x1` 0x5479b9, the kind mask, and `mov byte
// [esp+0x14],0x2` 0x5479be, the nearest selector). OWN DESIGN: 0, the default
// pair; server-database only. Under a non-zero word the runtime would also
// need the wider kind masks, which it does not carry.
const TacticsFlags uint32 = 0

// TacticsFlagsFastScan is the pair of flag bits that put a monster's scan on
// the fast timer: bit 2 (`test al,0x4` at 0x53f71b) or bit 7 (`test al,al;
// js` at 0x53f741..0x53f743, the sign of the low byte). Round 424 read the
// two as one flag.
const TacticsFlagsFastScan = 0x84

// The scan's cadence is tactics timer 1, armed once at AI::CTactics::Init
// (0x53f4d0) and polled by AITactics_AcquireTarget (`lea eax,[ctx+0x34]; mov
// ecx,0x1; call AITactics_TimerDue` at 0x547937..0x54793f), read from the asm
// because the decompile drops ArmTimer's register arguments (its index in ECX,
// its base in EAX; the spread on the stack). Init 0x53f712..0x53f765:
//
//	spread = 10 + |rand| % 491          ; `idiv` by 0x1eb at 0x53f755, `mov eax,0x3e8` at 0x53f757,
//	base   = 1000                       ;   `add edx,0xa` at 0x53f75c; the |rand| is the cdq/xor/sub idiom
//	         -- or, under flags & 0x84 --
//	spread = 10 + |rand| % 41           ; `idiv` by 0x29 at 0x53f738, `mov eax,0xc8` at 0x53f73a
//	base   = 200
//	push spread; mov ecx,1; call AITactics_ArmTimer (0x53d600 at 0x53f765)
//
// and AITactics_ArmTimer, on the first-table path index 1 takes (`cmp ecx,
// [ebx+4]; jle` at 0x53d60d; nine first-table entries, round 545):
//
//	period = base + |rand| % spread + 1 ; `div ebp` at 0x53d6ab, `lea edi,[edx+edi*1+0x1]` at 0x53d6ad
//	                                    ;   (the second table's twin is 0x53d64e..0x53d650)
//	(a second rand(), discarded)        ; `call 0x9dd338` at 0x53d6bb: nothing reads its result --
//	                                    ;   the second-table twin at 0x53d65e seeds that entry's
//	                                    ;   last (`div edi; add edx,[esp+0x18]; mov [esi+0x4],edx`
//	                                    ;   0x53d663..0x53d66b), the first-table path zeroes it
//	entry.last = 0, entry.fired = 1     ; 0x53d6c0, 0x53d6c7: due the first time it is asked
//	entry.period = period               ; 0x53d6d0
//
// so the period lies in [1001, 1500] ms, or [201, 250] on the fast branch,
// rolled once per spawn, and the first scan is immediate; the path draws
// rand() twice, the second draw to no effect but the engine's rng stream,
// which srrevamp's own rng does not share (round 555). AITactics_TimerDue
// (0x53d6e0) answers due on the fired byte (`cmp byte [..+1],1; je` 0x53d751)
// and otherwise once now - last >= period (`sub edx,[ecx+8]; cmp edx,[ecx+4];
// jb not-due` 0x53d75d..0x53d763), consuming it (`mov [ecx+4],edi` 0x53d765).
// The plan's own range for this, [1011, 1501], was wrong by the +1 and the
// spread's floor; the asm above is what settled it.
const (
	ScanPeriodBaseMs        = 1000 // 0x3e8 at 0x53f757
	ScanPeriodSpreadMin     = 10   // `add edx,0xa` at 0x53f75c
	ScanPeriodSpreadMod     = 491  // 0x1eb at 0x53f750
	ScanPeriodFastBaseMs    = 200  // 0xc8 at 0x53f73a
	ScanPeriodFastSpreadMod = 41   // 0x29 at 0x53f733
)

// ScanPeriodMs draws tactics timer 1's period for a row with the given flag
// word, in the engine's order: the spread first (Init), then ArmTimer's own
// draw. Every value lies in [1001, 1500], or [201, 250] under
// TacticsFlagsFastScan.
func ScanPeriodMs(rng *rand.Rand, flags uint32) int {
	base, mod := ScanPeriodBaseMs, ScanPeriodSpreadMod
	if flags&TacticsFlagsFastScan != 0 {
		base, mod = ScanPeriodFastBaseMs, ScanPeriodFastSpreadMod
	}
	spread := ScanPeriodSpreadMin + crand(rng)%mod
	return base + crand(rng)%spread + 1
}

// Aggressive is the aggression byte's verdict, rolled once at Init
// (0x53f5be..0x53f5e1) and fixed for the monster's life: ctx+0x168 is the
// row's mode as it is, except that mode 2 rolls `rand % 100 >= pct` into it
// (`cdq; idiv 100` 0x53f5d0..0x53f5d6, `cmp edx,[row+0x1c]; setge cl`
// 0x53f5db..0x53f5de) -- so under mode 2 a draw at or above the percent makes
// the byte 1, NOT aggressive. The scan then runs only while the byte is 0 or 3
// (AcquireTarget 0x547958..0x547964), which is why mode 1 never scans and a
// byte of 3 does; nothing in the roster's reach writes a 3, and the mode's
// documented values are 0/1/2 (monster_ai.md, column 7).
func Aggressive(rng *rand.Rand, mode uint8, pct int) bool {
	b := mode
	if mode == 2 {
		b = 0
		if crand(rng)%100 >= pct {
			b = 1
		}
	}
	return b == 0 || b == 3
}

// Candidate is one player the scan can pick: its character id and where it
// stands.
type Candidate struct {
	ID   int64
	X, Z float64
}

// Nearest is AITactics_Select_Nearest (0x5464e0, selector 2 of the ctx+0x128
// table) over cands in the order given, from the monster at (x, z) with the
// acquisition radius: the pick, its distance and whether there is one.
//
// In the engine's order for each candidate (a player: kind mask 1,
// GObj_MatchesKindMask 0x540b90):
//
//   - it must be at most trunc(radius) away: AcquireTarget converts ctx+0x15c
//     under RC=chop (`or eax,0xc00` 0x547989, `fldcw`, `fistp QWORD` 0x54799a)
//     and the selector compares that integer against the distance (`fild
//     [radius]; fcomp st(1); test ah,0x5; jnp reject` 0x54668d..0x5466a0:
//     rejected only when the radius is below the distance). The plan's
//     "round" was corrected here: the conversion truncates;
//   - it replaces the pick so far only when STRICTLY nearer than the pick's
//     distance as stored, and that store is the distance TRUNCATED (`fnstcw;
//     or eax,0xc00; fldcw; fistp QWORD` at 0x5466c8..0x5466e6 for the first
//     pick and 0x54673a..0x546758 after; the compare `fild [best]; fcomp
//     st(1); test ah,0x41; jne reject` at 0x546725..0x546738 rejects on
//     best < dist or best == dist). A stored 0 -- a pick under one unit away
//     -- is read as no pick yet (`mov eax,[edx]; cmp eax,ebx` with ebx = 0
//     at 0x546719..0x54671b; round 555 corrected the mnemonic, which read
//     `cmp [edx],ebx`), so any later candidate in range replaces it.
//     Carried as read.
//
// The distance srrevamp measures is the ground plane's, the one battleTick
// uses; GObj_DistanceBetween (0x53d7a0) sums three axes across regions, and
// srrevamp's monsters carry no height. The candidates' order is the caller's;
// the engine's is the region's player list, which srrevamp does not have.
//
// Not modelled, read closer in round 555: the PC branch (0x546563..0x546675)
// stores AITactics_ValidTargetOrNull's result back OVER the candidate (`mov
// [ebp+0x10],eax` 0x546590; `mov [ebp+0x10],ebx`, 0, at 0x5465a9 when the
// owner's slot 355 `[edx+0x58c]` refuses it), lets a nearer valid summoned
// object of that player (GObjPC::FUN_004fc160's list, 0x5465c2..0x546656)
// replace both the candidate (0x546646) and its distance (0x546642), reloads
// the result at 0x546675 and runs the two compares above on it with NO null
// test before the store (`mov [eax],esi` at 0x546702). So a player the
// validity test rejects -- dead, under -player-dead-state -- is not skipped
// the way Nearest's caller skips one: it leaves a NULL pick at its own
// distance, which a later candidate must be strictly nearer than. srrevamp's
// callers drop dead players before the scan, so a dead body nearer than a
// living player never shadows the living one here; in the engine it would.
func Nearest(cands []Candidate, x, z, radius float64) (best Candidate, dist float64, ok bool) {
	limit := math.Trunc(radius)
	stored := 0
	for _, c := range cands {
		d := math.Hypot(c.X-x, c.Z-z)
		if d > limit {
			continue
		}
		if ok && stored != 0 && float64(stored) <= d {
			continue
		}
		best, dist, ok, stored = c, d, true, int(d)
	}
	return best, dist, ok
}
