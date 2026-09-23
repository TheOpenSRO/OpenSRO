package systems

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Round 525 corrected two readings of the guild-point path in guild.md and
// guild.go, but docs/protocol/recovered_names.tsv -- the file the Ghidra
// applier writes back into the dumps -- kept the old wording until round 527:
//
//   - CGuildManager::RequestAddGuildPoints (0x5c62e0) answers 0x4c07 unless
//     the PC is ALIVE: 0x5c62fe loads vtable +0xf8, IGObj::GetLifeState
//     (docs/protocol/igobj_vtable.md, slot 62), and 0x5c6308 `cmp al,0x1`.
//     The row said "unless a PC".
//   - CGuild::AddPoints (0x5c4110) raises the member record's +0x40, which
//     docs/protocol/db_bind_offsets.tsv binds as _GUILDMEMBER GP_Donation;
//     Contribution is the separate column at +0x58. The row called the
//     type-6 broadcast "member contribution".
//
// This keeps both rows on the corrected reading. It reads the file at
// RUNTIME, so run it with -count=1 (see unwired_test.go).
func TestGuildPointRowsCarryRound525Corrections(t *testing.T) {
	root := repoRoot(t)
	raw, err := os.ReadFile(filepath.Join(root, "docs", "protocol", "recovered_names.tsv"))
	if err != nil {
		t.Fatalf("reading recovered_names.tsv: %v", err)
	}
	rows := map[string]string{}
	for _, line := range strings.Split(string(raw), "\n") {
		f := strings.Split(strings.TrimRight(line, "\r"), "\t")
		if len(f) < 5 || (f[0] != "005c62e0" && f[0] != "005c4110") {
			continue
		}
		if rows[f[0]] != "" {
			t.Fatalf("two rows for %s in recovered_names.tsv", f[0])
		}
		rows[f[0]] = f[4]
	}

	req := rows["005c62e0"]
	if req == "" {
		t.Fatal("no 005c62e0 (CGuildManager::RequestAddGuildPoints) row in recovered_names.tsv")
	}
	if strings.Contains(req, "0x4c07 unless a PC,") {
		t.Errorf("005c62e0 still says 0x4c07 is for a non-PC; 0x5c62fe-0x5c6308 test "+
			"GetLifeState == 1 (a living PC): %s", req)
	}
	if !strings.Contains(req, "GetLifeState") {
		t.Errorf("005c62e0 does not name the life test (vtable +0xf8, IGObj::GetLifeState): %s", req)
	}

	add := rows["005c4110"]
	if add == "" {
		t.Fatal("no 005c4110 (CGuild::AddPoints) row in recovered_names.tsv")
	}
	if strings.Contains(add, "(member contribution)") {
		t.Errorf("005c4110 still calls member+0x40 the contribution; it is _GUILDMEMBER "+
			"GP_Donation (Contribution is +0x58): %s", add)
	}
	if !strings.Contains(add, "GP_Donation") {
		t.Errorf("005c4110 does not name member+0x40 as GP_Donation: %s", add)
	}
}
