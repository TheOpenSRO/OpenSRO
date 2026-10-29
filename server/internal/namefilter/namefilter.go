// Package namefilter is SR_ShardManager's name filter (round 788, lane N):
// the test a new character's name and a new guild's name must pass, READ out
// of SR_ShardManager.exe (docs/protocol/charselect.md section 5, "The name
// rule"). It is CStringCheck's name half working on narrow (ANSI/DBCS) bytes,
// as the server's is; the client's twin, on UTF-16, is
// client/scripts/frontend/name_filter.gd.
//
// The rule (0x40f200, called by 0x40f300 for a character name and by 0x43b810
// for a guild name, after their own 2..12-byte length test):
//
//  1. no space (0x40f234: std::string::find(" "));
//  2. 0x527390, on the name lower-cased by 0x6df010: no `'` and no `"`
//     (scanning with CharNextA), and none of the 54 hard-coded SQL words
//     (SQLWords) found in it -- a byte-exact find, so the 11 mixed-case words
//     can never match;
//  3. 0x6df4c0, on the same lower-cased name: every character allowed by the
//     group's bitmap (0x6df7f0), none of the group's substring words found
//     at a character boundary (0x6df850) and the name, split on spaces, not
//     one of the group's whole words (0x6df970).
//
// The bitmap and the two word lists come from the operator's AbuseFilter.txt
// (Load); the group is the server's locale (GroupForLocale).
package namefilter

import (
	"strings"
)

// Groups is how many language groups AbuseFilter.txt holds (MEASURED: 36
// cells a line, 6 groups of 6) and the server's loader can select (READ
// 0x6dfb7b: a group above 5 skips no cell, i.e. reads group 0).
const Groups = 6

// GroupEnglish is the group the server uses for LOCALE_ENGLISH and for an
// unknown or missing locale (READ 0x40c862..0x40c870).
const GroupEnglish = 4

// Filter is one loaded name filter: the server object's +0x18 bitmap and its
// f1 word lists (+0x2018 substrings, +0x2048 whole words). The zero value
// refuses nothing; use Default or Load.
type Filter struct {
	group int
	// refused is the 65,536-bit table after the loader's final inversion: a
	// set bit is a refused code (READ 0x6e004a..: every byte inverted).
	refused [0x2000]byte
	// substr is the f1 == 2 list in file order (READ: pushed to the list at
	// +0x2018); whole is the f1 == 1 set (+0x2048). Both hold the cell as
	// 0x6df010 lower-cased it.
	substr []string
	whole  map[string]struct{}
	// stallSubstr and stallWhole are f4's lists (round 840): the stall
	// title's (+0x203c list, +0x20c0 set), as the loader lower-cased them.
	stallSubstr []string
	stallWhole  map[string]struct{}
	// allowRows counts the #ALLOW_ID_TABLE rows taken (for the boot log).
	allowRows int
}

// Default is the filter without a word list. READ: retail's loader, on a
// missing file, leaves the bitmap zeroed and never inverts it (the inversion
// is inside `if (hFile != INVALID_HANDLE_VALUE)`, 0x6dfa00), so it refuses no
// character at all. OURS (the coordinator's default, round 788): OpenSRO
// refuses every byte outside [0-9A-Za-z_] instead -- group 4's
// #ALLOW_ID_TABLE rows, which is also exactly what group 5's rows leave under
// the DBCS reading (its 0xC0..0xFF codes are below 0x100, and a byte >= 0x80
// is read as a code >= 0x8000; MEASURED on the retail file). The space,
// quote and SQL-word tests apply as always.
func Default() *Filter {
	f := &Filter{group: GroupEnglish, whole: map[string]struct{}{}, stallWhole: map[string]struct{}{}}
	for i := range f.refused {
		f.refused[i] = 0xff
	}
	for _, r := range [][2]int{{'0', '9'}, {'A', 'Z'}, {'_', '_'}, {'a', 'z'}} {
		for c := r[0]; c <= r[1]; c++ {
			f.allow(c)
		}
	}
	return f
}

func (f *Filter) allow(code int) { f.refused[code>>3] &^= 1 << (code & 7) }

func (f *Filter) isRefused(code int) bool { return f.refused[code>>3]&(1<<(code&7)) != 0 }

// Group is the language group the filter was built for.
func (f *Filter) Group() int { return f.group }

// Counts is what the filter holds: #ALLOW_ID_TABLE rows taken, substring
// words, whole words (for the boot log; never the words themselves).
func (f *Filter) Counts() (allowRows, substr, whole int) {
	return f.allowRows, len(f.substr), len(f.whole)
}

// NameOK is 0x40f200: true when name passes the space, quote and SQL-word
// tests and the group's filter. The caller has already applied its own length
// test (0x40c / 0x4c18).
func (f *Filter) NameOK(name string) bool {
	if strings.IndexByte(name, ' ') >= 0 {
		return false
	}
	if SQLHit(name) {
		return false
	}
	return f.filterOK(name)
}

// StallCounts is how many stall-title words the filter holds (f4's
// substring list and whole-word set), for the boot log.
func (f *Filter) StallCounts() (substr, whole int) { return len(f.stallSubstr), len(f.stallWhole) }

// StallTitleOK is the stall title's word test (round 840): the client's
// c:0x8c3f10 on f4's lists, which the original runs only in the client (the
// title box's OK, c:0x6bb159; SR_GameServer's CStringCheck loads f4's lists,
// s:0x9881f7, and no test reads them -- READ). On the title lower-cased (A-Z
// only, c:0x8c1660; here lowerDBCS on the narrow bytes): no f4 substring word
// found in it (c:0x8c3200, std::wstring::find, case-sensitive), then the
// title split on spaces (c:0x8c3060) with no token an f4 whole word
// (c:0x8c3ae0). No character bitmap, no SQL words, no length (the caller's).
// OURS: the server runs it too (session.stallTitleRefused), on the bytes the
// client sent.
func (f *Filter) StallTitleOK(title string) bool {
	low := lowerDBCS(title)
	for _, w := range f.stallSubstr {
		if strings.Contains(low, w) {
			return false
		}
	}
	if len(low) == 0 || len(f.stallWhole) == 0 {
		return true
	}
	return !tokensHit(low, f.stallWhole)
}

// SQLHit is 0x527390's verdict (READ; returns 1 on a hit): the name
// lower-cased by 0x6df010, then a `'` or `"` byte below 0x80 (the scan steps
// with CharNextA, which on OpenSRO's Windows-1252 model -- OURS, see Load --
// is one byte), then each of SQLWords found by std::string::find (0x418540:
// memchr + memcmp, case-sensitive).
func SQLHit(name string) bool {
	low := lowerDBCS(name)
	for i := 0; i < len(low); i++ {
		if b := low[i]; b == '\'' || b == '"' {
			return true
		}
	}
	for _, w := range SQLWords {
		if strings.Contains(low, w) {
			return true
		}
	}
	return false
}

// filterOK is 0x6df4c0 (READ): 1 when the lower-cased name passes the bitmap
// 0x6df7f0, misses every substring word 0x6df850 and is no whole word
// 0x6df970.
func (f *Filter) filterOK(name string) bool {
	low := lowerDBCS(name)
	if !f.bitmapOK(low) {
		return false
	}
	if f.substrHit(low) {
		return false
	}
	return !f.wholeHit(low)
}

// bitmapOK is 0x6df7f0 (READ): a byte below 0x80 is its own code; a byte at
// or above it is read with the next as one code (b<<8)|next, whatever the
// code page; a set bit refuses the name. OURS: a lead byte with nothing after
// it is read with a 0 trail and ends the scan (retail reads past the string's
// terminator there).
func (f *Filter) bitmapOK(low string) bool {
	for i := 0; i < len(low); {
		b := int(low[i])
		code := b
		if b >= 0x80 {
			trail := 0
			if i+1 < len(low) {
				trail = int(low[i+1])
			}
			code = b<<8 | trail
			i += 2
		} else {
			i++
		}
		if f.isRefused(code) {
			return false
		}
	}
	return true
}

// substrHit is 0x6df850 (READ): for each word no longer than the name, the
// name's windows of the word's length are compared with _stricmp (ASCII case
// folding), starting at offset 0 and stepping one byte past a byte below 0x80
// and two past one at or above it -- "character boundaries" in the DBCS
// sense, whatever the code page. The walk stops when fewer bytes remain than
// the word holds. OURS: it also stops at the end of the name where retail's
// unsigned count can step past a final lead byte.
func (f *Filter) substrHit(low string) bool {
	if len(low) == 0 {
		return false
	}
	for _, w := range f.substr {
		if len(w) > len(low) {
			continue
		}
		for p := 0; p < len(low) && len(low)-p >= len(w); {
			if asciiEqualFold(low[p:p+len(w)], w) {
				return true
			}
			if low[p]&0x80 != 0 {
				p += 2
			} else {
				p++
			}
		}
	}
	return false
}

// wholeHit is 0x6df970 (READ): the name split on spaces (0x6df660: the run
// up to the first space, then the rest after the spaces that follow), each
// token looked up exactly in the whole-word set. A name that reaches it has
// no space, so the token is the whole name.
func (f *Filter) wholeHit(low string) bool {
	if len(low) == 0 || len(f.whole) == 0 {
		return false
	}
	return tokensHit(low, f.whole)
}

// tokensHit is the space split (0x6df660 / c:0x8c3060) of low, each token
// looked up exactly in set.
func tokensHit(low string, set map[string]struct{}) bool {
	rest := low
	for {
		tok := rest
		if i := strings.IndexByte(rest, ' '); i >= 0 {
			tok, rest = rest[:i], rest[i:]
		} else {
			rest = ""
		}
		if _, hit := set[tok]; hit {
			return true
		}
		rest = strings.TrimLeft(rest, " ")
		if rest == "" {
			return false
		}
	}
}

// lowerDBCS is 0x6df010 (READ): A-Z become a-z; a byte at or above 0x80 is
// copied with the byte after it untouched (a DBCS pair, whatever the code
// page). OURS: a final lead byte is copied alone (retail copies the
// terminator and reads on).
func lowerDBCS(s string) string {
	b := []byte(s)
	for i := 0; i < len(b); {
		c := b[i]
		if c >= 0x80 {
			i += 2
			continue
		}
		if c >= 'A' && c <= 'Z' {
			b[i] = c + 0x20
		}
		i++
	}
	return string(b)
}

// asciiEqualFold is _stricmp's equality in the C locale: ASCII letters fold,
// every other byte compares as itself.
func asciiEqualFold(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := 0; i < len(a); i++ {
		x, y := a[i], b[i]
		if x >= 'A' && x <= 'Z' {
			x += 0x20
		}
		if y >= 'A' && y <= 'Z' {
			y += 0x20
		}
		if x != y {
			return false
		}
	}
	return true
}

// GroupForLocale is the server's locale -> group map (READ: server.cfg's
// LOCALE value compared by CompareStringA with NORM_IGNORECASE against
// LOCALE_KOREA..LOCALE_ENGLISH, 0x40cbf0..0x40cd30, storing 0..5; then the
// jump table 0x40cb20 at 0x40c7fa: 0->0, 1->1, 2->2, 3->3, VIETNAM 4->5,
// ENGLISH 5->4, anything else -> 4 with "Can't find associated locale
// setting"). Both the retail spelling ("LOCALE_VIETNAM") and the bare name
// ("VIETNAM") are taken, case-insensitively (OURS: the bare form). known is
// false for an unknown name, which maps to GroupEnglish as in retail.
func GroupForLocale(locale string) (group int, known bool) {
	s := strings.ToUpper(strings.TrimSpace(locale))
	s = strings.TrimPrefix(s, "LOCALE_")
	switch s {
	case "KOREA":
		return 0, true
	case "CHINA":
		return 1, true
	case "TAIWAN":
		return 2, true
	case "JAPAN":
		return 3, true
	case "VIETNAM":
		return 5, true
	case "ENGLISH":
		return 4, true
	}
	return GroupEnglish, false
}
