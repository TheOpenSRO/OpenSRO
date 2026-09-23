package systems

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The interaction-id vocabulary in docs/protocol/character_state.md ("The
// interaction-id vocabulary, from the NPCs themselves") once gave id 0xc to
// NPC_SD_GUILD_AGENT*, and round 458 repeated it as "specialty goods". No
// codename test in the server's CGObjNPCNPC::Create (0x4c6350) registers an id
// on them: their strstr chain (0x4c6d6b-0x4c6ddb) ends at 0x4c6ddd in vtable
// slot 198 (IGObj::SetBodyMode, docs/protocol/igobj_vtable.md, the table),
// never slot 89 (AddAvailableInteraction). The 0xc registrations are NPC_TD_THIEF_BUY
// (0x4c6ae1) and the NPC_*_SPECIAL chain (0x4c6f39). Round 520 corrected the
// table; this keeps the wrong attribution from coming back.
//
// It reads the doc at RUNTIME, so run it with -count=1 (see unwired_test.go).
func TestInteractionTableAgentsRegisterNoID(t *testing.T) {
	root := repoRoot(t)
	raw, err := os.ReadFile(filepath.Join(root, "docs", "protocol", "character_state.md"))
	if err != nil {
		t.Fatalf("reading character_state.md: %v", err)
	}
	var row0xc string
	agentRow := false
	for _, line := range strings.Split(string(raw), "\n") {
		if strings.HasPrefix(line, "| **0xc** |") {
			if row0xc != "" {
				t.Fatalf("two 0xc rows in the interaction-id table:\n%s\n%s", row0xc, line)
			}
			row0xc = line
		}
		if strings.HasPrefix(line, "|") &&
			strings.Contains(line, "NPC_SD_GUILD_AGENT") && strings.Contains(line, "SetBodyMode") {
			agentRow = true
		}
	}
	if row0xc == "" {
		t.Fatal("no '| **0xc** |' row in character_state.md's interaction-id table")
	}
	if strings.Contains(row0xc, "GUILD_AGENT") {
		t.Errorf("the 0xc row names the guild agents, but no codename test in CGObjNPCNPC::Create "+
			"registers an interaction id on them (0x4c6ddd is SetBodyMode, slot 198): %s", row0xc)
	}
	for _, want := range []string{"NPC_TD_THIEF_BUY", "NPC_CH_SPECIAL2", "NPC_SD_M_AREA_SPECIAL"} {
		if !strings.Contains(row0xc, want) {
			t.Errorf("the 0xc row lost %s, a literal the server registers 0xc on: %s", want, row0xc)
		}
	}
	if !agentRow {
		t.Error("no table row records that NPC_SD_GUILD_AGENT* reach SetBodyMode, not an id")
	}
}

// Round 455's table put id 0x11 "in the NPC_SIEGE_DUNGEON_TELEPORT block,
// beside 0x28", and called the arena NPCs' id "computed". Both are misreadings
// of CGObjNPCNPC::Create (0x4c6350) in /var/tmp/srv.asm. The siege block ends
// at 0x28's call (0x4c76d4); 0x11 is pushed at 0x4c77c2 behind no codename
// test, only the +0x42404 byte (0x4c76d6) and the map lookup FUN_004ccb70
// (0x4c77ac). The arena call at 0x4c75f9 has no push of its own: 0x21 is
// pushed at 0x4c75d1 (NPC_BATTLE_ARENA_MANAGER) and 0x22 at 0x4c75f5
// (NPC_BATTLE_ARENA_EXCHANGER), two literals into one shared call. Round 523
// corrected the rows; this keeps them corrected.
//
// It reads the doc at RUNTIME, so run it with -count=1 (see unwired_test.go).
func TestInteractionTable0x11AndArenaRows(t *testing.T) {
	root := repoRoot(t)
	raw, err := os.ReadFile(filepath.Join(root, "docs", "protocol", "character_state.md"))
	if err != nil {
		t.Fatalf("reading character_state.md: %v", err)
	}
	rows := map[string]string{}
	computedRow := ""
	for _, line := range strings.Split(string(raw), "\n") {
		for _, id := range []string{"0x11", "0x21", "0x22"} {
			if strings.HasPrefix(line, "| **"+id+"** |") {
				if rows[id] != "" {
					t.Fatalf("two %s rows in the interaction-id table:\n%s\n%s", id, rows[id], line)
				}
				rows[id] = line
			}
		}
		if strings.HasPrefix(line, "| computed |") {
			computedRow = line
		}
	}
	row11 := rows["0x11"]
	switch {
	case row11 == "":
		t.Error("no '| **0x11** |' row in character_state.md's interaction-id table")
	case strings.Contains(row11, "disputed") || strings.HasPrefix(row11, "| **0x11** | the `NPC_SIEGE_DUNGEON_TELEPORT` block"):
		t.Errorf("the 0x11 row still places the id in the siege-dungeon block, which ends at "+
			"0x28's call (0x4c76d4); 0x11 is pushed at 0x4c77c2 behind no codename test: %s", row11)
	default:
		for _, want := range []string{"0x4c77c2", "FUN_004ccb70", "+0x42404"} {
			if !strings.Contains(row11, want) {
				t.Errorf("the 0x11 row lost %s, part of the registration's grounding: %s", want, row11)
			}
		}
	}
	for id, want := range map[string]string{"0x21": "NPC_BATTLE_ARENA_MANAGER", "0x22": "NPC_BATTLE_ARENA_EXCHANGER"} {
		if !strings.Contains(rows[id], want) || !strings.Contains(rows[id], "0x4c75f9") {
			t.Errorf("the %s row must name %s and the shared call 0x4c75f9: %q", id, want, rows[id])
		}
	}
	if computedRow != "" {
		t.Errorf("a 'computed' row is back; the arena ids are the literals 0x21 (0x4c75d1) and "+
			"0x22 (0x4c75f5): %s", computedRow)
	}
}
