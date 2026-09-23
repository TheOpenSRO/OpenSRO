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
