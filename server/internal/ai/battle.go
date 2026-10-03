package ai

// The pure BATTLE rules (round 545): whether a monster's target is still worth
// chasing, and the give-up code the engine would send it home with. Every rule
// below was read out of SR_GameServer.exe; the addresses are cited at each,
// and docs/protocol/monster_ai.md, "The pure BATTLE rules and the timer read
// (round 545)", holds the reading in full. Nothing runs them yet: they are
// inert until mob-battle-chase wires them into session/monsterai.go's BATTLE
// tick, where the interim hold (round 539) stands today.
//
// The _RefTactics row these rules read is server-database only
// (monster_ai.md, "The _RefTactics row, read off its parser"), so the four
// columns they need are OWN-DESIGN stand-ins, one constant each, each
// disclosed at the constant. The engine's tests run in this order on every
// BATTLE tick (CAIState_BATTLE::OnUpdate 0x55a090): the target must be valid
// (AITactics_ValidTargetOrNull 0x540dc0 at 0x55a0dc, else message 0x23 ->
// IDLE at 0x55a116), then the reach test (behaviour +0x100,
// AITactics_TargetOutOfReach 0x548120 at 0x55a175: 1 -> message 0x27 -> IDLE,
// pushed at 0x55a187), then the give-up check (behaviour +0x104,
// AITactics_BattleGiveUpCheck 0x5483c0 at 0x55a1a2: 2 -> message 0x2a with
// its code at 0x55a1b9), then the swing (behaviour +0xe8 at 0x55a1d0).

// TacticsChaseSwitch stands in for _RefTactics column 35 (row +0x79), the
// chase rule's switch. 0 and 2 disable both distance tests: IsTargetWithinChaseRange
// answers "within" at once (`cmp byte [eax+0x79],0` 0x545e5c and `cmp ..,2`
// 0x545e6f, both `je 0x545f5a`, which is `mov al,1`) and BattleGiveUpCheck
// answers "no code" (`test al,al; je` 0x5483de, `cmp al,2; je` 0x5483e2, both
// to `xor eax,eax`). 1 enables them. OWN DESIGN: the column is server-database
// only and no roster value was read; 1 is the one value under which the two
// rules do anything, and a monster that never gives up its target is not what
// OpenSRO wants (Init 0x53f4d0 also asserts an immobile monster with a
// detection distance has +0x79 == 1, monster_ai.md column 35).
const TacticsChaseSwitch uint8 = 1

// TacticsGiveUpDistance stands in for column 36 (row +0x7c), the give-up
// distance in world units (`fild [eax+0x7c]` at 0x545e60 and at 0x54842a).
// OWN DESIGN: 400, twice the 200 of session.MonsterRoamRadius (itself own
// design), so a chase can run a monster to the far edge of its roam circle
// and as far again before its target is out of reach; the real column is
// server-database only and no value for it was read anywhere.
const TacticsGiveUpDistance = 400.0

// TacticsReachRule stands in for column 40 (row +0x89), the byte
// AITactics_TargetOutOfReach (0x548120) switches on after the two flag
// asserts (round 424): `mov al,[edx+0x89]` 0x548158; 0 -> the chase-range
// test (`test al,al; jbe 0x548182`); 1 or 2 -> out of reach at once
// (`cmp al,2; jbe 0x548179`, which is `mov eax,1`); 3 -> out of reach while
// AITactics_HPBucket (0x541d70, at 0x54816a) answers under 2, HP under 40%
// (`cmp eax,2; setge al`); any other value -> the chase-range test. The test
// itself is TargetWithinChaseRange negated (`call 0x545e50` 0x54818d;
// `neg al; sbb eax,eax; add eax,1`). OWN DESIGN: 0, the only value under which
// a monster chases at all; the column is server-database only.
const TacticsReachRule uint8 = 0

// TacticsRetargetRule stands in for column 9 (row +0x20), the rule
// AITactics_Handler_0fc (0x548090, behaviour +0xfc, which
// CAIState_BATTLE::OnAttacked 0x55a2e0 calls on a blow while in BATTLE)
// applies after the attacker accounting: RetargetKeepFirst keeps the first
// attacker (no SetTarget at all), RetargetLatest faces the latest, and
// RetargetByHate asks the threat table (ThreatTable.FaceAfterHit, round 259).
// OWN DESIGN: RetargetKeepFirst, the interim hold's behaviour since round 537;
// the column is server-database only. mob-threat-retarget revisits it.
const TacticsRetargetRule uint8 = RetargetKeepFirst

// GiveUpCheckPeriodMs is the period of tactics timer 6, the one
// AITactics_BattleGiveUpCheck gates its distance test on (`mov ecx,6`
// 0x5483f0, `call AITactics_TimerDue` 0x5483f5, `test eax,eax; jg` 0x5483fa:
// not due -> return 0, no code). AI::CTactics::Init arms it once, with base
// 0x5dc and spread 0 (`mov eax,0x5dc` 0x53f6ec, `mov ecx,6` 0x53f6f1, `push 0`
// for the spread at 0x53f6ea, `call AITactics_ArmTimer` 0x53f6f6), and nothing
// else arms index 6 (every `call 0x53d600` in the image was listed). Index 6
// is a first-table index (CAITimeManager::InitTables 0x53d4b0 gives the first
// table 9 entries, `mov dword [ebp+4],9` at 0x53d4bb; ArmTimer's split is
// `cmp ecx,[ebx+4]; jle` at 0x53d60d), and every first-table arming marks the
// entry fired (`mov byte [esi+1],1` 0x53d6c7) with last = 0 (0x53d6c0), so the
// timer is due the first time it is asked (TimerDue: `cmp byte [..+1],1; je`
// 0x53d751 -> `mov [ecx+4],edi` 0x53d765, `mov eax,1` 0x53d76c) and every
// GiveUpCheckPeriodMs after that consumption (`sub edx,[ecx+8]; cmp edx,[ecx+4];
// jb not-due` 0x53d75d..0x53d763: due once now - period >= last). So the give-up
// distance is tested on the first BATTLE tick and then at most every 1.5 s;
// between tests the check returns 0 and BATTLE goes on to the swing.
const GiveUpCheckPeriodMs = 1500

// ChaseRange is the threshold IsTargetWithinChaseRange (0x545e50) compares
// the target's distance against on its nest path (ctx+0x30 non-zero:
// `cmp [ebx+0x30],0; jne 0x545eae` at 0x545e8e): the raw give-up distance
// (row +0x7c) reduced by how far the monster stands beyond 1.5 x its nest
// radius, and untouched inside that circle:
//
//	excess    = |monster - nest position| - radius x 1.5   ; 0x545eef FUN_00430ad0, 0x545ef7 length (0x405270),
//	                                                       ; 0x545efc fld [ebx+0x1cc], 0x545f02 fmul QWORD 0xb45d78 (1.5), 0x545f0c fsub
//	threshold = +0x7c - excess  when excess > 0            ; 0x545f1a fcom against 0.0, `test ah,0x41; jne 0x545f2f` keeps +0x7c
//	          = +0x7c           otherwise                  ; 0x545f25 fsubr [esp+0xc], the +0x7c stored at 0x545e65
//
// The position is the six-field record at ctx+0x1b4 copied by Location_Copy
// (0x4115d0 at 0x545eba) -- the nest's own position on this path -- and the
// radius is ctx+0x1cc, the nest's own radius (monster_ai.md, column 38's
// note: AI::CTactics::Attach stores refNest+0x20 there when there is a nest).
// The multiplier is the same double WithinRoamRadius reads under rule 1
// (RoamRule1Factor). OpenSRO treats each placement as a nest whose position
// is the spawn point and whose radius is session.MonsterRoamRadius (own
// design, monsterai.go), so the chase item passes those. The reduction can
// take the threshold below zero, and the engine compares it as it is.
func ChaseRange(giveUp, roamRadius, distFromHome float64) float64 {
	excess := distFromHome - roamRadius*RoamRule1Factor
	if excess > 0 {
		return giveUp - excess
	}
	return giveUp
}

// TargetWithinChaseRange is AITactics_IsTargetWithinChaseRange (0x545e50)
// for a target dist away, the test AITactics_TargetOutOfReach ends in under
// reach rule 0 (TacticsReachRule): true while the target is still worth
// chasing. In the engine's order:
//
//   - chaseSwitch (row +0x79) 0 or 2 -> within (`cmp byte [eax+0x79],0`
//     0x545e5c and `cmp ..,2` 0x545e6f, both `je 0x545f5a`: `mov al,1`);
//   - giveUp (row +0x7c, `fild` 0x545e60) == 0 -> within (`fucom` against
//     0.0 at 0x545e7f, `test ah,0x44; jnp 0x545f58`: C3 alone, equal, jumps);
//   - no nest (ctx+0x30 == 0, 0x545e8e): within iff dist < giveUp, STRICT
//     (`fld [ebp+8]` the distance, `fcompp` 0x545e97, `test ah,0x5; jnp
//     0x545f5a`: C0 alone -- dist below giveUp -- jumps to `mov al,1`; an
//     equal distance sets C3 only, parity even, and falls to `xor al,al`);
//   - a nest: within iff dist <= ChaseRange(giveUp, roamRadius,
//     distFromHome), INCLUSIVE (`fld [ebp+8]` then `fld [esp+0xc]` the
//     threshold, `fcompp` 0x545f38 with the threshold in st(0), `test ah,0x1;
//     jne 0x545f4e`: only threshold < dist reaches `xor eax,eax`; equal
//     reaches `mov eax,1` at 0x545f41).
//
// nest picks the path; every OpenSRO placement is a nest. Not modelled, and
// disclosed: on the nest path the engine first asks
// Location_SameOrAdjacentRegion (0x430ce0 at 0x545ecc) whether the monster's
// own location record (owner +0x84) and the nest's share a world and lie in
// the same or an adjacent region, and answers "out" when they do not
// (`test al,al; je 0x545ea4` at 0x545ed1, `xor al,al`). A region is 1920
// units, so that needs a monster farther from its nest than
// TacticsGiveUpDistance lets any chase run under the stand-ins; OpenSRO's
// monsters have no region record to compare anyway.
func TargetWithinChaseRange(dist float64, chaseSwitch uint8, giveUp float64, nest bool, roamRadius, distFromHome float64) bool {
	if chaseSwitch == 0 || chaseSwitch == 2 || giveUp == 0 {
		return true
	}
	if !nest {
		return dist < giveUp
	}
	return dist <= ChaseRange(giveUp, roamRadius, distFromHome)
}

// GiveUpCode is the code AITactics_BattleGiveUpCheck (0x5483c0, behaviour
// +0x104) writes for message 0x2a when it answers 2, or 0 when it sends no
// message, for a target dist away under the row's chase switch and RAW
// give-up distance:
//
//   - chaseSwitch 0 or 2 -> 0 (`mov al,[eax+0x79]` 0x5483db; `test al,al; je`
//     0x5483de and `cmp al,2; je` 0x5483e2, both to `xor eax,eax` 0x5483d1);
//   - dist >= giveUp -> 1 (`fild [eax+0x7c]` 0x54842a with the distance
//     already in st(0), `fcompp` 0x54842d comparing giveUp against dist,
//     `test ah,0x41; jp 0x548444` 0x548431: C0 alone -- giveUp below dist --
//     or C3 alone -- equal -- is odd parity and falls through to `mov byte
//     [edi],1` 0x548436, then `mov eax,2` 0x54843b). The base handler for
//     0x2a (CAIState::OnMsg_0x2a 0x559ad0) turns a 1 into ChangeState(1),
//     IDLE, the same fallback message 0x27 takes.
//
// Not modelled, and disclosed. The timer gate is the caller's: the distance
// test runs only when tactics timer 6 is due (GiveUpCheckPeriodMs). The flag
// gate is not carried: a row whose +0x90 word has bit 2 or bit 7 gets 0 before
// anything else (`test cl,4` 0x5483cc, `test cl,cl; js` 0x5483d7; round 421),
// and OpenSRO holds no flag word. Nearer than giveUp, once 5000 ms have
// passed since the last swing (ctx+0xcc: `sub ecx,[esi+0xcc]; cmp ecx,0x1388;
// jb` 0x54844a..0x548456 returns 0 inside the window), the code is 3 when
// dist >= 100.0 (the float at 0xb45e10, read: 00 00 c8 42) for a target whose
// slot 304 (`[edx+0x4c0]` 0x54845a) answers 1, else >= 150.0 (0xb45f04, read:
// 00 00 16 43), and 2 below either; OnMsg_0x2a turns 2 and 3 into a 0x704f
// notice, not a transition (recovered_names.tsv, 0x559ad0), so the chase item
// has no use for them and this returns 0 there.
//
// Under OpenSRO's stand-ins (TacticsChaseSwitch 1, TacticsReachRule 0) a 1
// is all but unreachable, because the reach test runs first and exits by
// 0x27. With no nest it never is: within iff dist < giveUp, code 1 iff
// dist >= giveUp, and the two never both hold. With a nest it is only at dist
// exactly giveUp with the monster inside 1.5 x its radius (ChaseRange
// untouched), where the inclusive reach test keeps the target and this sends
// the monster to IDLE by 0x2a(1) instead of 0x27 -- the same state either way.
// Anywhere the reduction bites, dist > ChaseRange comes first.
func GiveUpCode(dist float64, chaseSwitch uint8, giveUp float64) uint8 {
	if chaseSwitch == 0 || chaseSwitch == 2 {
		return 0
	}
	if dist >= giveUp {
		return 1
	}
	return 0
}

// TargetOutOfReach is AITactics_TargetOutOfReach (0x548120, behaviour
// +0x100, the reach test BATTLE::OnUpdate runs first) under the tactics row's
// column 40 (+0x89, btFleeType) -- round 660, when the row is a monster's own
// (EXTERNAL) rather than TacticsReachRule's stand-in. READ (monster_ai.md,
// column 40; round 424's asserts): rule 1 or 2 is out of reach at once (`cmp
// al,2; jbe` to `mov eax,1`); rule 3 is out of reach while AITactics_HPBucket
// (0x541d70) answers under 2 -- HP under 40 % of the maximum -- and otherwise
// the chase-range test decides; rule 0 and any other value are the chase-range
// test (TargetWithinChaseRange, handed in as within) negated. hpFrac is the
// monster's HP over its maximum. Every row the shard's matched nests use
// carries rule 0 (the round-660 census), so only the last branch runs today.
func TargetOutOfReach(rule uint8, hpFrac float64, within bool) bool {
	switch rule {
	case 1, 2:
		return true
	case 3:
		if hpFrac < 0.4 {
			return true
		}
	}
	return !within
}
