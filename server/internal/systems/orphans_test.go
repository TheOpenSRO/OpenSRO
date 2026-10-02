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
	// internal/ai, unparked in round 537 when session/monsterai.go began driving
	// the state machine behind -monster-ai. These are the recovered rules that
	// tick does not run yet, each with the item that will call it.
	"AggroLinkHate": "the hate each successive link carries (the record's +8 floored at 1 and scaled " +
		"by MONSTER_AGGRO_LINK_DECREASE_RATIO, round 258, corrected in round 537, named in round 553). " +
		"The link itself is wired (round 553, session/monsterai.go's linkAggro, behind -monster-battle) " +
		"but forwards no hate: a blow carries no hate value in srrevamp, and the magnitudes are the " +
		"threat table's -- wired by mob-threat-retarget.",
	"AttackIntervalRange": "a monster's swing interval, ReuseDelay + rand % (J + 1) (ArmNextAttack " +
		"0x5619e0, round 259). Round 545's timer read settled that the jitter never delays a swing: " +
		"the interval is only ever armed on a first-table timer, which fires at once (ArmTimer " +
		"0x53d6c7), so the swing cadence is the action machine's ReuseDelay (round 254) and this " +
		"range is the threat table's idle window only -- wired by mob-threat-retarget.",
	"Credit": "the threat table's attacker accounting (AITactics_CreditAttacker 0x5473c0, round 259); " +
		"the interim hold keeps the first attacker without it -- wired by mob-threat-retarget.",
	"FaceAfterHit": "the threat table's retarget rules, col 9 = 0/1/2 (Handler_0fc 0x548090, round " +
		"259) -- wired by mob-threat-retarget.",
	"Clear": "the threat table's SetTarget(0) reset (round 259) -- wired by mob-threat-retarget.",
	"SetBurnTable": "installs the 0xc63c94 word table burn's tick divides (round 659). The table " +
		"is read out of the operator's own server binary and is not copied into the repository " +
		"(docs/LEGAL.md); no loader supplies it yet, so a burn lands, shows and expires but deals 0 " +
		"a tick -- OPEN in docs/TODO.md.",
	"StateByBit": "the client-bit -> state lookup of the round-278 vocabulary. The server works in " +
		"skill codes and slots (StateByCode, SlotForBit); the client resolves bits itself " +
		"(StatusNet). Knowledge, not a gap; the tests hold the table to it.",
	"DwellRange": "the closed [min, max] of each AIState_DwellMs arm; the tick draws with " +
		"ai.DwellMs, and the tests hold every draw to this range. No item needs the range itself at " +
		"run time: knowledge, not a gap.",
	"WanderDistanceRange": "the closed 46..124 of PickWanderLeg's leg length; the tick draws with " +
		"ai.PickWanderLeg, and the tests hold the legs (and the AI tick's leg starts) to it. No item " +
		"needs the range itself at run time: knowledge, not a gap.",
	"HomingScatterRange": "the closed R/3 .. R/3 + trunc(R/3) band of MoveHome (round 535); the tick " +
		"draws with ai.HomeDestination, and the tests hold its destinations to this band. No item " +
		"needs the band itself at run time: knowledge, not a gap.",
	// internal/teleport, added in round 575. Round 576's session.TeleportHandler
	// calls the lookups and rules a gate's MOVE needs; what is left is the
	// destination LIST, which the client builds from its own copy of the tables
	// (UI_TELEPORT::FUN_006fd3e0 reads the client's link records,
	// teleport_network.md "The client's list, read"), so no server message
	// carries it yet. PointByBuildingCode left the list in round 686: the
	// return point resolves a race's gate by its code (session.returnPointFor).
	"LinksFrom": "a gate's outgoing links in file order, the destination list the talk box shows. The " +
		"client builds that list from its own teleportlink rows, as the retail dialog does " +
		"(UI_TELEPORT::FUN_006fd3e0); the server answers only the MOVE (session.TeleportHandler, " +
		"round 576). Knowledge until a server-side list message exists.",
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
	"CanCreate":           "internal/party/party.go",
	"CanDeclareWar":       "internal/guild/war.go",
	"CanRequestAlliance":  "internal/guild/alliance.go",
	"CapDamage":           "internal/combat/combat.go",
	"CombatHandler":       "internal/session/combat.go",
	"Complete":            "internal/equipment/itemset.go",
	"DefaultWearFamily":   "internal/equipment/defaultwear.go",
	"DeriveSeed":          "internal/proto/security.go",
	"EquipmentHandler":    "internal/session/equipment.go",
	"EquippedIn":          "internal/session/world.go",
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
