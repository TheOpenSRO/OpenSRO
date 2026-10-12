package session

import (
	"math"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/skillparam"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// words builds a Params column: the action kind, then code runs.
func words(kind int32, runs ...[]any) []int32 {
	out := []int32{kind}
	for _, r := range runs {
		out = append(out, skillparam.WordOf(skillparam.Code(r[0].(string))))
		for _, v := range r[1:] {
			out = append(out, int32(v.(int)))
		}
	}
	return out
}

func run(code string, v ...int) []any {
	out := []any{code}
	for _, x := range v {
		out = append(out, x)
	}
	return out
}

// TestActionBlockRoundTrip pins the retail tail's layout (FUN_00585730 /
// FUN_005856d0 / FUN_005855f0, docs/protocol/skill_hit_block.md): nested
// per target, kinds 0/4/5 with two u32s, 4/5 with the position, 7 with the
// wall's u16 pair, 2 with nothing, then the move and the OURS kinds.
func TestActionBlockRoundTrip(t *testing.T) {
	b := &ActionBlock{Target: 7, TargetKind: ActionTargetMonster, HitCount: 2, Flags: ActionFlagMove,
		MoveRegion: 0x61a8, MoveX: 10, MoveY: -3, MoveZ: 1900,
		Targets: []ActionTarget{
			{UID: 7, Kind: ActionTargetMonster, Hits: []ActionHit{
				{Kind: HitKindDamage, Flags: HitFlagCritical, Damage: 1234, Status: 0x80},
				{Kind: HitKindKnockdown | HitDied, Flags: HitFlagNormal, Damage: 5, Region: 0x61a8, X: 1, Y: 2, Z: 3},
			}},
			{UID: 9, Kind: ActionTargetMonster, Hits: []ActionHit{
				{Kind: HitKindBlocked},
				{Kind: HitKindWall, Flags: 1, Damage: 40, WallHP: 60, WallMax: 100},
			}},
		}}
	enc := b.encode(nil)
	// marker, u32 target, u8 flags (1|8), u8 hits, u8 targets, then target 7:
	// u32, hit (1+4+4), hit (1+4+4+2+12); target 9: u32, hit (1), hit (1+4+2+2);
	// move (2+12); kinds (2); leading kind (1).
	want := 1 + 4 + 1 + 2 + (4 + 9 + 23) + (4 + 1 + 9) + 14 + 2 + 1
	if len(enc) != want {
		t.Fatalf("encoded %d bytes, want %d", len(enc), want)
	}
	if enc[5] != ActionFlagDamage|ActionFlagMove {
		t.Fatalf("flags %#x", enc[5])
	}
	got, rest, err := DecodeActionBlock(append(enc, 0xEE))
	if err != nil || len(rest) != 1 || rest[0] != 0xEE {
		t.Fatalf("decode: %v rest %v", err, rest)
	}
	if got.Targets[0].Hits[1].Kind != HitKindKnockdown|HitDied || got.Targets[0].Hits[1].Z != 3 ||
		got.Targets[0].Hits[0].Damage != 1234 || got.Targets[0].Hits[0].Flags != HitFlagCritical ||
		got.Targets[1].Hits[1].WallHP != 60 || got.MoveZ != 1900 || got.Targets[1].Kind != ActionTargetMonster {
		t.Fatalf("decoded %+v", got)
	}
}

// TestAttackResultCarriesTheBlock: a result with an action block writes the
// wall suffix (zero) first, so the block sits at offset 72 after the error
// string, and an older decoder's fields are unchanged.
func TestAttackResultCarriesTheBlock(t *testing.T) {
	r := &AttackResult{MonsterID: 5, MonsterDamage: 9, Action: &ActionBlock{Target: 5, HitCount: 1,
		Targets: []ActionTarget{{UID: 5, Kind: ActionTargetMonster, Hits: []ActionHit{{Flags: 1, Damage: 9}}}}}}
	enc := r.Encode()
	got, err := DecodeAttackResult(enc)
	if err != nil || got.Action == nil || got.Action.Targets[0].Hits[0].Damage != 9 || got.MonsterDamage != 9 || got.Wall != (WallInfo{}) {
		t.Fatalf("decoded %+v %v", got, err)
	}
	if enc[2+72] != actionBlockMarker {
		t.Fatalf("marker not at 72: % x", enc[2+59:2+76])
	}
}

// TestTeleportClamp: FUN_005862e0 (READ) lands ON a point within the limit
// (3-D) and clamps one beyond it along the line; the landing is truncated.
func TestTeleportClamp(t *testing.T) {
	from := world.Position{X: 0, Y: 0, Z: 0}
	if got := teleportDestination(from, world.Position{X: 30, Y: 0, Z: 40}, 100); got.X != 30 || got.Z != 40 {
		t.Fatalf("near point moved to %+v", got)
	}
	got := teleportDestination(from, world.Position{X: 300, Y: 0, Z: 400}, 100)
	if math.Abs(got.X-60) > 1e-9 || math.Abs(got.Z-80) > 1e-9 {
		t.Fatalf("far point clamped to %+v", got)
	}
	// Ghost Walk B lv1's own limit, from the row's Params ('tele' 500,100).
	row := &refdata.Skill{ParamWords: words(0, run("tele", 500, 100))}
	if l, f, ok := groundMove(row); !ok || l != 100 || f != ActionFlagMove {
		t.Fatalf("groundMove = %v %v %v", l, f, ok)
	}
	row = &refdata.Skill{ParamWords: words(0, run("tel2", 500, 125))}
	if l, f, ok := groundMove(row); !ok || l != 125 || f != ActionFlagSnap {
		t.Fatalf("tel2 groundMove = %v %v %v", l, f, ok)
	}
	if _, _, ok := groundMove(&refdata.Skill{ParamWords: words(0, run("tel3", 500, 80))}); ok {
		t.Fatal("'tel3' is no ground move")
	}
	if p := sprintDestination(from, world.Position{X: 50}, 10, 80); p.X != 40 {
		t.Fatalf("sprint landed at %+v, want 10 short of the target", p)
	}
}

// TestEfrShares: b = 100 - v4, then trunc((100-v4) b / 100) (READ 0x58a487).
func TestEfrShares(t *testing.T) {
	s := newEfrShares(35)
	var got []int
	for i := 0; i < 7; i++ {
		got = append(got, s.take())
	}
	want := []int{65, 42, 27, 17, 11, 7, 4}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("shares %v, want %v", got, want)
		}
	}
	if areaShare(10, 4) != 1 || areaShare(100, 65) != 65 || areaShare(0, 50) != 0 {
		t.Fatal("areaShare")
	}
}

// TestCollectAreaAroundTarget: kind 2 takes the monsters within casterBC +
// v2 + tBC of the primary, nearest first, up to the cap, with falloff.
func TestCollectAreaAroundTarget(t *testing.T) {
	mons := combat.NewHub()
	p := mons.Spawn("z", "p", 100, 0, 0, 100, 0, 0, 0)
	a := mons.Spawn("z", "a", 110, 0, 0, 100, 0, 0, 0)
	b := mons.Spawn("z", "b", 100, 0, 15, 100, 0, 0, 0)
	far := mons.Spawn("z", "far", 200, 0, 0, 100, 0, 0, 0)
	row := &refdata.Skill{ParamWords: words(0, run("efr", 1, 2, 20, 3, 35, 24))}
	caster := world.Entity{Zone: "z", Pos: world.Position{X: 90}}
	pm, _ := mons.Get(p.ID)
	got := collectSkillTargets(row, caster, pm, mons, 6)
	if len(got) != 3 || got[0].ID != p.ID || got[0].Share != 100 || got[1].ID != a.ID || got[1].Share != 65 || got[2].ID != b.ID || got[2].Share != 42 {
		t.Fatalf("targets %+v (far %d)", got, far.ID)
	}
	// Without the object bit (v5 & 0x10) no monster joins.
	row = &refdata.Skill{ParamWords: words(0, run("efr", 1, 2, 20, 3, 35, 8))}
	if got := collectSkillTargets(row, caster, pm, mons, 6); len(got) != 1 {
		t.Fatalf("no object bit: %+v", got)
	}
}

// TestCollectLine: kind 3's beam along caster -> primary, Action_Range long.
func TestCollectLine(t *testing.T) {
	mons := combat.NewHub()
	p := mons.Spawn("z", "p", 20, 0, 0, 100, 0, 0, 0)
	on := mons.Spawn("z", "on", 40, 0, 1, 100, 0, 0, 0)
	off := mons.Spawn("z", "off", 40, 0, 30, 100, 0, 0, 0)
	row := &refdata.Skill{Range: 60, ParamWords: words(0, run("efr", 1, 3, 2, 3, 25, 24))}
	pm, _ := mons.Get(p.ID)
	got := collectSkillTargets(row, world.Entity{Zone: "z"}, pm, mons, 0)
	if len(got) != 2 || got[1].ID != on.ID || got[1].Share != 75 {
		t.Fatalf("line %+v (off %d)", got, off.ID)
	}
}

// TestRowHasMAAT: the mastery scaling follows 'getv MAAT' (0x59e770).
func TestRowHasMAAT(t *testing.T) {
	maat := skillparam.WordOf("MAAT")
	with := &refdata.Skill{Mastery1: 1, ParamWords: []int32{0, skillparam.WordOf("getv"), maat}}
	without := &refdata.Skill{Mastery1: 1, ParamWords: []int32{0, skillparam.WordOf("getv"), skillparam.WordOf("E1SA")}}
	if !rowHasMAAT(with) || rowHasMAAT(without) || !rowHasMAAT(&refdata.Skill{Mastery1: 1}) {
		t.Fatal("MAAT gate")
	}
}
