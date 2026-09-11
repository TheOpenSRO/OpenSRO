// Package leveldata holds the EXP-per-level curve recovered from the client's
// own server_dep\silkroad\textdata\leveldata.txt (see docs/LEVELING.md), and
// the level-up math built on it. The curve is game data, so it is never
// committed: an operator generates a CSV from their own client with
// cmd/export-leveldata and points the server at it (SRREVAMP_LEVELDATA_CSV).
// Without it the server has no curve and characters do not level.
package leveldata

import (
	"bufio"
	"fmt"
	"io"
	"sort"
	"strconv"
	"strings"
)

// StatPointsPerLevel is how many points a character gets to spend (into Str or
// Int) each level. Recovered as a rule, not a table value: a real level-9
// character window showed 24 stat points, and (9-1)*3 = 24. See docs/LEVELING.md.
const StatPointsPerLevel = 3

// MaxCharacterLevel is the hard level cap this client enforces, recovered from
// the client's own EXP handler: sro_client.exe FUN_008a97c0 runs its level-up
// carry loop `while (level != 'n')` -- 'n' is 0x6E = 110 -- and force-stops at
// that level. It is independent of the leveldata.txt row count (that table has
// 139 rows; a character still stops at 110). This is this specific client's
// base-game cap; a later expansion's client would raise it. See
// docs/GROUNDING_AUDIT.md.
const MaxCharacterLevel = 110

// Table is the level -> EXP-to-advance curve. expToNext[L] is the experience a
// character must accumulate at level L to reach level L+1.
type Table struct {
	expToNext map[int]int64
	maxLevel  int
}

// ExpToNext returns the EXP needed to advance from level, and whether level is
// in the table (the max level has no "next", so it returns false there).
func (t *Table) ExpToNext(level int) (int64, bool) {
	if t == nil {
		return 0, false
	}
	v, ok := t.expToNext[level]
	return v, ok
}

// MaxLevel is the highest level the curve defines. A character at MaxLevel does
// not advance further.
func (t *Table) MaxLevel() int {
	if t == nil {
		return 0
	}
	return t.maxLevel
}

// Loaded reports whether a real curve is present (an operator imported one).
func (t *Table) Loaded() bool { return t != nil && len(t.expToNext) > 0 }

// Advance applies gained EXP to a character at (level, exp), where exp is the
// progress already accumulated at level. It returns the new level, the new
// progress, and how many levels were gained. A nil/empty table gains no levels
// and accumulates exp unbounded, so a server with no curve still tracks raw
// progress.
//
// The carry model is RECOVERED from the client, not assumed: sro_client.exe's
// EXP handler FUN_008a97c0 does exactly this -- on each level it subtracts that
// level's requirement from the running EXP and increments the level in a loop
// (excess EXP rolls into the next level), stopping when the EXP is below the
// next level's requirement OR the level reaches the cap 'n' (110,
// MaxCharacterLevel). At the cap it does NOT zero the bar: it holds EXP at that
// level's requirement minus one (a full-but-not-overflowing bar). See
// docs/GROUNDING_AUDIT.md.
func (t *Table) Advance(level int, exp int64, gained int64) (newLevel int, newExp int64, levelsGained int) {
	newLevel = level
	newExp = exp + gained
	if !t.Loaded() {
		return newLevel, newExp, 0
	}
	// The effective cap is the client's hard cap or the last level the table
	// actually defines, whichever comes first (a shorter table can't advance
	// past its last row).
	levelCap := t.maxLevel
	if MaxCharacterLevel < levelCap {
		levelCap = MaxCharacterLevel
	}
	for {
		need, ok := t.expToNext[newLevel]
		if !ok || newLevel >= levelCap {
			// At the cap, hold EXP just below this level's requirement, the
			// way the client does (FUN_008a97c0) -- not zeroed.
			if newLevel >= levelCap && ok && newExp >= need {
				newExp = need - 1
			}
			break
		}
		if newExp < need {
			break
		}
		newExp -= need
		newLevel++
		levelsGained++
	}
	return newLevel, newExp, levelsGained
}

// ParseCSV reads "level,expToNext" rows (a header line and blank lines are
// skipped) into a Table.
func ParseCSV(r io.Reader) (*Table, error) {
	t := &Table{expToNext: map[int]int64{}}
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	line := 0
	for scanner.Scan() {
		line++
		text := strings.TrimSpace(scanner.Text())
		if text == "" {
			continue
		}
		fields := strings.Split(text, ",")
		if len(fields) < 2 {
			return nil, fmt.Errorf("leveldata: line %d: want 'level,exp', got %q", line, text)
		}
		level, err := strconv.Atoi(strings.TrimSpace(fields[0]))
		if err != nil {
			// The first line may be a header ("level,exp") -- skip a
			// non-numeric level rather than fail.
			if line == 1 {
				continue
			}
			return nil, fmt.Errorf("leveldata: line %d: level %q: %w", line, fields[0], err)
		}
		exp, err := strconv.ParseInt(strings.TrimSpace(fields[1]), 10, 64)
		if err != nil {
			return nil, fmt.Errorf("leveldata: line %d: exp %q: %w", line, fields[1], err)
		}
		t.expToNext[level] = exp
		if level > t.maxLevel {
			t.maxLevel = level
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("leveldata: reading CSV: %w", err)
	}
	// The max level is the top of the curve, which itself has no "next" -- so
	// treat the highest level present as the cap (a character there does not
	// advance). Guard against gaps by taking the real max.
	if len(t.expToNext) > 0 {
		levels := make([]int, 0, len(t.expToNext))
		for l := range t.expToNext {
			levels = append(levels, l)
		}
		sort.Ints(levels)
		t.maxLevel = levels[len(levels)-1]
	}
	return t, nil
}
