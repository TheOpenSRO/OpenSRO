package systems

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// WHY THIS TEST EXISTS.
//
// Twice now a mechanic has been recovered from the binary, implemented
// faithfully, tested -- and never called by anything, for weeks, without
// anyone noticing:
//
//   - mana.RegenPerTick, the HP/MP regen rule, had no caller outside its own
//     tests until a player reported that health never came back.
//   - refdata.MonsterDrop.RollAssignedDrop and the real drop tables sat behind
//     ONE missing field (combat.Monster.RefObjID) from 2026-09-15 to
//     2026-09-20, while every kill rolled the own-design placeholder table.
//
// Both were found by accident. The signature is mechanical, so it can be a
// test instead: an internal package that nothing outside itself imports is
// either deliberately parked, or it is a mechanic one wire away from shipping
// that nobody remembers.
//
// This test does not forbid parking -- most of these packages are recovered
// RULE SETS with no system to attach to yet, which is a legitimate and honest
// thing for this project to hold. It forbids parking SILENTLY. Every package
// with no shipping importer must say why, here, in one line.
//
// A CAVEAT ABOUT CACHING, the same one that hid a failure in this package for
// eleven rounds: this test reads .go files at RUNTIME, and Go's test cache
// keys on the package's own inputs, not on files opened during the run. A
// plain `go test` can replay a stale PASS after the tree changes. Run the
// suite with `-count=1`; CI does a fresh checkout and so always sees the truth.

// parked lists every internal package with no non-test importer, and why.
//
// Adding a line here is a deliberate act: it says "this is recovered knowledge
// we are keeping, not a mechanic we forgot to wire". Removing one is what
// happens when the mechanic ships.
var parked = map[string]string{
	// Infrastructure -- these are not game mechanics at all.
	"systems": "this package: it parses docs/SYSTEMS.md so tests can hold the repo to it",
	"testdb":  "a test helper, imported only by tests by design",

	// File-format readers kept for tooling and documentation, not used by the
	// running server.
	// (efp left this list in round 619: cmd/efpcensus imports it.)
	"environment": "parses environment.ifo; lighting is a client concern, kept here with the other format readers",

	// Recovered rule sets with no system in OpenSRO to attach to. Each one
	// says so in its own package doc; this is the index of them.
	"academy":     "recovered training-camp rules; OpenSRO has no training camp",
	"arena":       "recovered battle-arena shape; its own doc opens 'OpenSRO has no arena'",
	"persistence": "the recovered DB surface of the real server, a specification rather than a store",
	"siege":       "recovered fortress-war rules; its own doc says OpenSRO 'is not about to grow one'",

	// "ai" left this map in round 537: session/monsterai.go imports it and
	// drives the state machine behind cmd/server's -monster-ai (off by
	// default). Its functions nothing calls yet are now explained one by one
	// in orphans_test.go's knownOrphans, each with the item that wires it.
}

// unimportedInternalPackages returns the internal packages that no non-test
// file outside the package itself imports.
func unimportedInternalPackages(t *testing.T) []string {
	t.Helper()
	root := repoRoot(t)
	internal := filepath.Join(root, "server", "internal")

	entries, err := os.ReadDir(internal)
	if err != nil {
		t.Fatalf("reading %s: %v", internal, err)
	}
	var pkgs []string
	for _, e := range entries {
		if e.IsDir() {
			pkgs = append(pkgs, e.Name())
		}
	}
	if len(pkgs) < 10 {
		// The probe must be able to fail. If the tree walk finds almost
		// nothing, the paths are wrong and every later assertion is vacuous.
		t.Fatalf("only found %d internal packages under %s; the walk is broken", len(pkgs), internal)
	}

	// Collect every non-test .go file in the server module once.
	type file struct {
		pkg  string
		body string
	}
	var files []file
	serverDir := filepath.Join(root, "server")
	err = filepath.Walk(serverDir, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return err
		}
		b, readErr := os.ReadFile(path)
		if readErr != nil {
			return readErr
		}
		rel, _ := filepath.Rel(internal, path)
		owner := ""
		if !strings.HasPrefix(rel, "..") {
			owner = strings.SplitN(filepath.ToSlash(rel), "/", 2)[0]
		}
		files = append(files, file{pkg: owner, body: string(b)})
		return nil
	})
	if err != nil {
		t.Fatalf("walking %s: %v", serverDir, err)
	}

	var out []string
	for _, p := range pkgs {
		needle := "OpenSRO/server/internal/" + p + `"`
		imported := false
		for _, f := range files {
			if f.pkg == p {
				continue // a package importing itself is not a shipping use
			}
			if strings.Contains(f.body, needle) {
				imported = true
				break
			}
		}
		if !imported {
			out = append(out, p)
		}
	}
	sort.Strings(out)
	return out
}

// The probe has to be able to report BOTH states, or it proves nothing. If
// every package came back unimported the walk would be broken, and this is
// where that shows up rather than in a confident empty diff below.
func TestTheUnwiredProbeCanTellTheTwoStatesApart(t *testing.T) {
	unimported := unimportedInternalPackages(t)
	root := repoRoot(t)
	entries, _ := os.ReadDir(filepath.Join(root, "server", "internal"))
	total := 0
	for _, e := range entries {
		if e.IsDir() {
			total++
		}
	}
	if len(unimported) == 0 {
		t.Fatal("the probe found NO unimported packages, which contradicts its own parked list: the walk is broken")
	}
	if len(unimported) == total {
		t.Fatalf("the probe reports all %d internal packages unimported: the import match is broken", total)
	}
	t.Logf("%d of %d internal packages have no non-test importer", len(unimported), total)
}

// Every package with no shipping importer must be declared, with a reason.
func TestUnwiredPackagesAreDeclared(t *testing.T) {
	for _, p := range unimportedInternalPackages(t) {
		reason, ok := parked[p]
		if !ok {
			t.Errorf("internal/%s has no non-test importer and is not declared in parked.\n"+
				"This is the shape that hid the HP-regen rule and the real drop tables: recovered,\n"+
				"implemented, tested, and never called. Either wire it up, or add a line to parked\n"+
				"saying why it is knowledge rather than a gap.", p)
			continue
		}
		if strings.TrimSpace(reason) == "" {
			t.Errorf("internal/%s is declared in parked with an empty reason", p)
		}
	}
}

// And the list must not rot: a package that HAS been wired should not still be
// listed as parked, or the next reader is told a gap exists that does not.
func TestParkedListHasNoStaleEntries(t *testing.T) {
	unimported := map[string]bool{}
	for _, p := range unimportedInternalPackages(t) {
		unimported[p] = true
	}
	var stale []string
	for p := range parked {
		if !unimported[p] {
			stale = append(stale, p)
		}
	}
	sort.Strings(stale)
	for _, p := range stale {
		t.Errorf("internal/%s is listed as parked but something now imports it: remove it from parked", p)
	}
}
