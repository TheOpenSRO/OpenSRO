package namefilter

import (
	"fmt"
	"os"
	"unicode/utf16"
)

// LoadFile reads an AbuseFilter.txt for group (0..5). The file is the
// operator's: the server's own copy beside SR_ShardManager.exe, or the
// client's Media.pk2 server_dep\silkroad\textdata\abusefilter.txt (the two
// retail copies differ; deploy/README.md). It is never shipped.
func LoadFile(path string, group int) (*Filter, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return Load(data, group)
}

// Load builds the filter for group from an AbuseFilter.txt's bytes the way
// SR_ShardManager's loader 0x6dfa00 does (READ):
//
//   - the file is UTF-16LE; its first two bytes are skipped whatever they
//     are (the BOM) and the remaining (size/2 - 1) units converted to ANSI
//     with WideCharToMultiByte(CP_ACP). OURS: the ANSI code page is
//     Windows-1252 (cp1252.go) -- a character it lacks becomes '?', the code
//     page's default character -- since a Go server has no system code page.
//     Retail's DBCS servers (Korea, China, Taiwan, Japan) would have used
//     theirs; the bitmap does not depend on it (its codes are numbers), only
//     the words do;
//   - lines end at CR LF only, and the tokenizer's comments apply: from the
//     first '/' on a line, "//" cuts the rest of the line and "/*" cuts it and
//     skips lines up to the first "*/" (READ 0x6e1be0); empty lines are
//     skipped (0x6e1df0);
//   - on each line the group's cells are reached by skipping 6 x group tab
//     separators (0x6dfbd4..0x6dfc07); a line too short for the group gives
//     nothing;
//   - the group's first cell is read up to the next TAB, CR or NUL (not
//     trimmed) and lower-cased by 0x6df010. "#allow_id_table" (exactly; the
//     file's own "#ALLOW_ID_TABLE") marks the codes from..to, the next two
//     numbers, as allowed; any other non-empty cell is a word with four flag
//     numbers after it, of which the first, f1, is the name test's: 1 puts the
//     word in the whole-word set (+0x2048), 2 on the substring list (+0x2018),
//     anything else nowhere. f2 (chat), f3 (guild-related) and f4 (stall)
//     are the GameServer's and the client's, not read here;
//   - a number skips leading whitespace (space and 0x01..0x10, so tabs and
//     empty cells too), needs a digit next (after an optional sign) or reads
//     as 0 without moving, and is decimal or, with an x in second place, hex
//     (0x6e1970) -- so an empty flag cell borrows the next cell's number,
//     exactly as retail's does;
//   - after the last line the whole table is inverted: a set bit refuses.
//
// group outside 0..5 reads group 0 (READ: the loader's switch leaves the skip
// at 0); GroupForLocale never returns one.
func Load(data []byte, group int) (*Filter, error) {
	if len(data) < 2 {
		return nil, fmt.Errorf("namefilter: %d bytes is not a UTF-16 file", len(data))
	}
	n := len(data)/2 - 1
	units := make([]uint16, n)
	for i := 0; i < n; i++ {
		units[i] = uint16(data[2+2*i]) | uint16(data[3+2*i])<<8
	}
	text := encodeCP1252(utf16.Decode(units))

	f := &Filter{group: group, whole: map[string]struct{}{}, stallWhole: map[string]struct{}{}}
	skip := 0
	if group >= 0 && group < Groups {
		skip = 6 * group
	}
	lines := newLineReader(text)
	for {
		line, ok := lines.next()
		if !ok {
			break
		}
		c := &cursor{s: line}
		c.skipCells(skip)
		if c.pos >= len(c.s) {
			continue
		}
		cell := lowerDBCS(c.readCell())
		if cell == "#allow_id_table" {
			from := c.readInt() & 0xffff
			to := c.readInt() & 0xffff
			// Still the loader's polarity: a set bit is an allowed code.
			for code := from; code <= to; code++ {
				f.refused[code>>3] |= 1 << (code & 7)
			}
			f.allowRows++
			continue
		}
		if cell == "" {
			continue
		}
		f1 := c.readInt()
		switch f1 {
		case 1:
			f.whole[cell] = struct{}{}
		case 2:
			f.substr = append(f.substr, cell)
		}
		// Round 840: f4, the stall title's flag. The loader reads all four
		// flags in order (READ s:0x987cb0 / c:0x8c4a10: f4 1 -> the set at
		// +0x20c0, 2 -> the list at +0x203c); f2 and f3 are read past.
		c.readInt()
		c.readInt()
		switch c.readInt() {
		case 1:
			f.stallWhole[cell] = struct{}{}
		case 2:
			f.stallSubstr = append(f.stallSubstr, cell)
		}
	}
	// The loader zeroed the table, set a bit per allowed code, and inverts it
	// here: from now on a set bit is a refused code.
	for i := range f.refused {
		f.refused[i] = ^f.refused[i]
	}
	return f, nil
}

// lineReader is 0x6e1be0 over CR LF lines (0x6e1b70 with its +0x34 mode 0:
// only CR LF ends a line; a lone CR or LF stays in it; a NUL ends it).
type lineReader struct {
	s         string
	pos       int
	inComment bool
}

func newLineReader(s string) *lineReader { return &lineReader{s: s} }

// rawLine is the next CR LF (or NUL) terminated line, or false at the end.
func (r *lineReader) rawLine() (string, bool) {
	if r.pos >= len(r.s) {
		return "", false
	}
	start := r.pos
	for i := start; i < len(r.s); i++ {
		switch {
		case r.s[i] == 0:
			r.pos = i + 1
			return r.s[start:i], true
		case r.s[i] == '\r' && i+1 < len(r.s) && r.s[i+1] == '\n':
			r.pos = i + 2
			return r.s[start:i], true
		}
	}
	r.pos = len(r.s)
	return r.s[start:], true
}

// next is 0x6e1df0: the next line after comments that is not empty.
func (r *lineReader) next() (string, bool) {
	for {
		line, ok := r.commentLine()
		if !ok {
			return "", false
		}
		if line != "" {
			return line, true
		}
	}
}

// commentLine is 0x6e1be0: a line outside a comment is cut at its first '/'
// when a '/' or '*' follows (the latter opening a block); inside a block, a
// line is skipped unless its first '*' is followed by '/', and then what
// follows the "*/" is the line. Only the first '/' or '*' on a line is
// looked at (READ: the scan breaks on it).
func (r *lineReader) commentLine() (string, bool) {
	for {
		line, ok := r.rawLine()
		if !ok {
			return "", false
		}
		if !r.inComment {
			for i := 0; i < len(line); i++ {
				if line[i] != '/' {
					continue
				}
				if i+1 < len(line) {
					switch line[i+1] {
					case '*':
						r.inComment = true
						line = line[:i]
					case '/':
						line = line[:i]
					}
				}
				break
			}
			return line, true
		}
		for i := 0; i < len(line); i++ {
			if line[i] != '*' {
				continue
			}
			if i+1 < len(line) && line[i+1] == '/' {
				r.inComment = false
				return line[i+2:], true
			}
			break
		}
	}
}

// cursor is the tokenizer's position in one line.
type cursor struct {
	s   string
	pos int
}

// skipCells is the loader's own walk to the group (0x6dfbd4..0x6dfc07): past
// skip tab separators; it stops early at the end of the line.
func (c *cursor) skipCells(skip int) {
	if skip <= 0 {
		return
	}
	count := 0
	for c.pos < len(c.s) {
		ch := c.s[c.pos]
		if ch != 0 {
			c.pos++
			if ch != '\t' {
				continue
			}
		}
		if c.pos >= len(c.s) {
			return
		}
		count++
		if count >= skip {
			return
		}
	}
}

// isDelim is the loader's cell delimiters: NUL, TAB and CR (READ 0x6dfb53..
// 0x6dfb6f, three calls to 0x6e1760).
func isDelim(ch byte) bool { return ch == 0 || ch == '\t' || ch == '\r' }

// isSpace is 0x6e1860: a space or 0x01..0x10.
func isSpace(ch byte) bool { return ch == ' ' || (ch >= 0x01 && ch <= 0x10) }

// readCell is 0x6e1ac0: the bytes up to the next delimiter, which stays.
func (c *cursor) readCell() string {
	start := c.pos
	for c.pos < len(c.s) && !isDelim(c.s[c.pos]) {
		c.pos++
	}
	return c.s[start:c.pos]
}

func (c *cursor) skipSpace() {
	for c.pos < len(c.s) && c.s[c.pos] != 0 && isSpace(c.s[c.pos]) {
		c.pos++
	}
}

func isDigit(ch byte) bool { return ch >= '0' && ch <= '9' }

func isHexLetter(ch byte) bool { return (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F') }

// readInt is 0x6e1970 (with 0x6e18b0's look-ahead): see Load.
func (c *cursor) readInt() int32 {
	// 0x6e18b0: after whitespace and an optional sign, is a digit next? The
	// position is put back either way.
	saved := c.pos
	c.skipSpace()
	var ch byte
	if c.pos < len(c.s) {
		ch = c.s[c.pos]
		c.pos++
		if ch == '-' || ch == '+' {
			ch = 0
			if c.pos < len(c.s) {
				ch = c.s[c.pos]
				c.pos++
			}
		}
	}
	c.pos = saved
	if !isDigit(ch) {
		return 0
	}
	c.skipSpace()
	start := c.pos
	positive := true
	first, count := 0, 0
	hex := false
	for c.pos < len(c.s) && c.s[c.pos] != 0 {
		ch := c.s[c.pos]
		if (ch == 'x' || ch == 'X') && count == 1 {
			first, hex = 2, true
		} else if !(isDigit(ch) || (hex && isHexLetter(ch))) {
			if count != 0 {
				break
			}
			if ch == '-' {
				positive = false
			} else if ch != '+' {
				break
			}
			first = 1
		}
		c.pos++
		count++
	}
	var v int32
	digits := c.s[start : start+count]
	for i := first; i < count; i++ {
		d := digits[i]
		if hex {
			switch {
			case d >= 'a' && d <= 'f':
				d -= 0x57
			case d >= 'A' && d <= 'F':
				d -= 0x37
			default:
				d -= '0'
			}
			v = v*16 + int32(int8(d))
		} else {
			v = v*10 + int32(int8(d-'0'))
		}
	}
	if !positive {
		v = -v
	}
	return v
}
