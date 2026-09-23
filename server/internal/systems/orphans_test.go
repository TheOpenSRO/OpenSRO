package systems

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// WHY THIS EXISTS, and why it took three attempts.
//
// Three times now a mechanic has been recovered from the binary, implemented
// faithfully, tested, and then never called: mana.RegenPerTick (players stopped
// healing), the real monster drop tables (every kill rolled a placeholder for
// five days), and skill.WithdrawCost. Each was found by accident.
//
// unwired_test.go catches the PACKAGE-level version. It cannot catch these,
// because the packages are imported -- only the function is orphaned.
//
// TWO GREP-BASED RULES WERE TRIED AND BOTH FAILED, which is why this parses:
//
//  1. "flag exported funcs whose doc comment claims recovery" found ZERO and
//     missed the known positive: skill.WithdrawCost's comment is four
//     paragraphs of derivation that never uses the word "recovered".
//  2. "flag exported funcs with no reference outside their own file" reported
//     252 of 548, because a function called by its neighbour twenty lines down
//     is still called. Fixing that gave 70 -- but it STILL missed
//     WithdrawCostForLevels, because `grep` counts the name in its own doc
//     comment as a use.
//
// An AST walk has neither problem: ast.Ident nodes are code, comments are not
// part of the expression tree at all.

// decodeSurfaceNote explains the one exclusion that is not a judgement call.
const decodeSurfaceNote = "Decode* in internal/session is the wire-decoding surface: " +
	"the Godot client consumes those messages over the socket, so nothing in Go calls them"

// knownOrphans are exported functions deliberately kept without a caller, each
// with the reason. An entry here is a claim that the code is knowledge rather
// than a gap -- the same contract as unwired_test.go's parked list.
var knownOrphans = map[string]string{
	"DeathPenaltyFactorFor": "the per-cause EXP death penalty. Triaged out of the baseline in " +
		"round 351: cause 5 (the lesser, 20x branch) requires BOTH parties to be guilded -- " +
		"GObjPC::IsKilledByPlayer tests victim+0x1cbc and killer[0x72f], which are PARTY and " +
		"GUILD -- so it is a guild-war or siege death. srrevamp has neither, and its only PvP is " +
		"a consensual duel, which duel.go declines to charge for because which death kind a duel " +
		"is has not been read. Unreachable until srrevamp grows open-world PK, not forgotten.",
	"WithdrawCostForLevels": "the recovered skill-reset cost formula; srrevamp offers no " +
		"withdrawal feature (docs/protocol/skill_withdraw.md says so in its first paragraph). " +
		"This entry is also this test's positive CONTROL -- see TestOrphanDetectorIgnoresComments.",
	"DecodeMovement": "the receiving half of the real 0x7021 movement payload " +
		"(docs/protocol/opcodes/movement.md, round 365). The SENDING half is reachable -- " +
		"Movement.Encode and EncodeMovementAngle are both called -- but nothing in Go decodes " +
		"a 0x7021 yet, because srrevamp's gateway still speaks the placeholder opcodes " +
		"PROTOCOL_DECISION.md calls scaffolding, and a real client is what would send this. " +
		"Kept as the matching half of a codec rather than shipped one-sided: a format recovered " +
		"in one direction only is how a layout gets half-checked. Delete this line the moment " +
		"the gateway accepts a real 0x7021.",
}

// baseline is the set of orphans that existed when this detector was written.
// **These are NOT reviewed.** Listing one is not a claim that it is fine -- it
// is a claim that it is not NEW. The test's job is to stop the set growing
// silently, which is the failure it was built for; triaging the 46 is separate
// work and each line records where to look.
//
// Two classes were obvious on the first run and are worth naming here:
//
//   - CombatHandler and UseSkillHandler were superseded by the ...WithDrops
//     constructors added in round 332 when the real drop tables were wired.
//     cmd/server calls the new ones; these survive only in tests.
//   - NewRollingByte, NewPacketChecksum and DeriveSeed are the packet-security
//     primitives. Nothing calls them because session crypto is not implemented,
//     which PACKET_FORMAT.md's status list already states.
//
// Removing a line when its function gets wired (or deleted) is the point.
var baseline = map[string]string{
	"Accumulated":         "internal/combat/chancememory.go",
	"AllMeshPaths":        "internal/bsr/bsr.go",
	"AreaTargetShare":     "internal/skillparam/paramblock.go",
	"ArmorClassOf":        "internal/equipment/defaultwear.go",
	"ArmourLossSlot":      "internal/durability/durability.go",
	"BonusTier":           "internal/equipment/itemset.go",
	"BuffEndsAt":          "internal/skillparam/paramblock.go",
	"CanCreate":           "internal/party/party.go",
	"CanDeclareWar":       "internal/guild/war.go",
	"CanRequestAlliance":  "internal/guild/alliance.go",
	"CapDamage":           "internal/combat/combat.go",
	"CharacterHandler":    "internal/session/character.go",
	"CombatHandler":       "internal/session/combat.go",
	"Complete":            "internal/equipment/itemset.go",
	"DefaultWearFamily":   "internal/equipment/defaultwear.go",
	"DeriveSeed":          "internal/proto/security.go",
	"EquipmentHandler":    "internal/session/equipment.go",
	"EquippedIn":          "internal/session/world.go",
	"Find":                "internal/skillparam/paramblock.go",
	"Has":                 "internal/guild/guild.go",
	"IntForMaxRatio":      "internal/combat/statratio.go",
	"IntLevelDamageRatio": "internal/combat/statratio.go",
	"IsPhysical":          "internal/combat/attacktype.go",
	"ListAllSkills":       "internal/refdata/memstore.go",
	"NewPacketChecksum":   "internal/proto/security.go",
	"NewRollingByte":      "internal/proto/security.go",
	"NewTestSession":      "internal/gateway/gateway.go",
	"PackTag":             "internal/combat/paramtags.go",
	"ReinforceRates":      "internal/refdata/item.go",
	"ReplyOpcode":         "internal/proto/opcodes.go",
	"ScaleHPForMonster":   "internal/combat/rarity.go",
	"SessionOf":           "internal/trade/trade.go",
	"SetBlocked":          "internal/account/memstore.go",
	"SetSecurity":         "internal/gateway/gateway.go",
	"SetsWorn":            "internal/equipment/itemset.go",
	"Spawn":               "internal/combat/combat.go",
	"StrForMaxRatio":      "internal/combat/statratio.go",
	"StrLevelDamageRatio": "internal/combat/statratio.go",
	"TruncateForTest":     "internal/equipment/sqlstore.go",
	"UnpackTag":           "internal/combat/paramtags.go",
	"UseSkillHandler":     "internal/session/skill.go",
	"WorldHandler":        "internal/session/world.go",
}

type decl struct {
	name string
	pos  token.Pos
	file string
	pkg  string
}

// exportedOrphans parses the server tree and returns exported top-level funcs
// and methods that no other *code* refers to.
func exportedOrphans(t *testing.T) ([]decl, int) {
	t.Helper()
	root := filepath.Join(repoRoot(t), "server")
	fset := token.NewFileSet()

	var files []*ast.File
	var paths []string
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return err
		}
		if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		// parser.SkipObjectResolution keeps this fast; comments are not
		// requested at all, which is the whole point.
		f, perr := parser.ParseFile(fset, path, nil, parser.SkipObjectResolution)
		if perr != nil {
			return perr
		}
		files = append(files, f)
		paths = append(paths, path)
		return nil
	})
	if err != nil {
		t.Fatalf("parsing the server tree: %v", err)
	}
	if len(files) < 50 {
		t.Fatalf("only parsed %d files under %s; the walk is broken", len(files), root)
	}

	decls := map[string][]decl{}
	for i, f := range files {
		rel, _ := filepath.Rel(root, paths[i])
		pkg := filepath.Dir(rel)
		for _, d := range f.Decls {
			fd, ok := d.(*ast.FuncDecl)
			if !ok || fd.Name == nil {
				continue
			}
			// UNEXPORTED FUNCTIONS COUNT TOO, added round 353. Round 352 found
			// `wornBroken` -- an unexported helper encoding a recovered rule,
			// written and never called -- and this detector could not see it,
			// because it only walked exported declarations. That is the same
			// bug class it exists to catch, hiding one visibility level down.
			//
			// init and main are entry points the runtime calls, not orphans.
			if fd.Name.Name == "init" || fd.Name.Name == "main" {
				continue
			}
			decls[fd.Name.Name] = append(decls[fd.Name.Name],
				decl{name: fd.Name.Name, pos: fd.Name.Pos(), file: rel, pkg: pkg})
		}
	}

	// Every identifier the code actually mentions, excluding the declaration's
	// own name node.
	declPos := map[token.Pos]bool{}
	for _, ds := range decls {
		for _, d := range ds {
			declPos[d.pos] = true
		}
	}
	used := map[string]bool{}
	for _, f := range files {
		ast.Inspect(f, func(n ast.Node) bool {
			id, ok := n.(*ast.Ident)
			if !ok || declPos[id.Pos()] {
				return true
			}
			if _, isDecl := decls[id.Name]; isDecl {
				used[id.Name] = true
			}
			return true
		})
	}

	var out []decl
	for name, ds := range decls {
		if used[name] {
			continue
		}
		out = append(out, ds[0])
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].pkg != out[j].pkg {
			return out[i].pkg < out[j].pkg
		}
		return out[i].name < out[j].name
	})
	return out, len(files)
}

func isDecodeSurface(d decl) bool {
	return strings.HasPrefix(d.name, "Decode") && d.pkg == filepath.Join("internal", "session")
}

// isParkedPackage reuses unwired_test.go's declaration rather than restating
// it. A package already explained as parked -- a recovered rule set with no
// system to attach to -- explains its functions too, so requiring a second
// reason per function would be noise, and a duplicate list would rot.
func isParkedPackage(d decl) bool {
	_, ok := parked[filepath.Base(d.pkg)]
	return ok && filepath.Dir(d.pkg) == "internal"
}

// The detector must not repeat the grep's mistake of counting a name in its own
// doc comment as a use. WithdrawCostForLevels is mentioned in exactly one place
// besides its declaration -- the comment line above it -- and is called from
// nowhere, so a comment-blind detector must report it and a comment-counting one
// cannot.
func TestOrphanDetectorIgnoresComments(t *testing.T) {
	orphans, nfiles := exportedOrphans(t)
	t.Logf("parsed %d files, %d exported orphans", nfiles, len(orphans))

	found := false
	for _, d := range orphans {
		if d.name == "WithdrawCostForLevels" {
			found = true
		}
	}
	if !found {
		t.Error("WithdrawCostForLevels was not reported.\n" +
			"It is referenced only by its own doc comment, so either the detector is counting\n" +
			"comments as uses -- the exact bug this test exists to prevent -- or the function has\n" +
			"since been wired up, in which case remove it from knownOrphans and pick a new control.")
	}

	// And the opposite direction: something plainly called must not be reported.
	for _, d := range orphans {
		if d.name == "KillExp" || d.name == "MitigateDamage" {
			t.Errorf("%s reported as an orphan, but it is called; the detector is broken", d.name)
		}
	}
}

// Every exported function with no caller must be explained: either it is the
// wire-decoding surface, or it is declared in knownOrphans with a reason.
func TestEveryOrphanIsExplained(t *testing.T) {
	orphans, _ := exportedOrphans(t)
	for _, d := range orphans {
		if !ast.IsExported(d.name) {
			// An unexported function cannot be a package's public surface, so
			// none of the exemptions below can apply to it: it is either called
			// from its own package or it is dead. There were 296 of them and
			// exactly ONE orphan when this was added, and that one was deleted
			// rather than listed, so the invariant here is ZERO.
			t.Errorf("%s (%s) is unexported and nothing calls it.\n"+
				"Either it is dead code, or it is a recovered rule nobody wired -- which is how\n"+
				"wornBroken sat unused until round 352. Delete it or call it; there is no third\n"+
				"option for an unexported function, and no baseline for these.", d.name, d.file)
			continue
		}
		if isDecodeSurface(d) || isParkedPackage(d) {
			continue
		}
		if _, ok := baseline[d.name]; ok {
			continue
		}
		if reason, ok := knownOrphans[d.name]; ok {
			if strings.TrimSpace(reason) == "" {
				t.Errorf("%s is in knownOrphans with an empty reason", d.name)
			}
			continue
		}
		t.Errorf("%s (%s) is exported and nothing calls it.\n"+
			"This is the shape that hid the HP-regen rule, the real drop tables and the skill-reset\n"+
			"cost formula: recovered, implemented, tested, never called. Either wire it up, or add a\n"+
			"line to knownOrphans saying why it is knowledge rather than a gap.\n"+
			"(%s)", d.name, d.file, decodeSurfaceNote)
	}
}

// And the list must not rot: an entry that has since been wired should go.
func TestKnownOrphansHaveNoStaleEntries(t *testing.T) {
	orphans, _ := exportedOrphans(t)
	live := map[string]bool{}
	for _, d := range orphans {
		live[d.name] = true
	}
	for name := range knownOrphans {
		if !live[name] {
			t.Errorf("%s is listed in knownOrphans but something now calls it: remove the entry", name)
		}
	}
	for name := range baseline {
		if !live[name] {
			t.Errorf("%s is in the baseline but something now calls it (or it was deleted): remove the line", name)
		}
	}
}
