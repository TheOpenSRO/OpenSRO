package namefilter

// OpenSRO's stand-in for the server's ANSI code page (OURS, round 788):
// Windows-1252. SR_ShardManager converts AbuseFilter.txt with
// WideCharToMultiByte(CP_ACP) (READ 0x6dfa00); a Go server has no system code
// page, and the retail English and Vietnamese groups' words are all
// Windows-1252 but one (MEASURED on both retail copies: one CJK character in
// group 4, none in group 5). A character the code page lacks becomes '?',
// Windows' default character for it. Windows' "best fit" mapping (which turns,
// say, a fullwidth letter into its ASCII twin when WC_NO_BEST_FIT_CHARS is not
// passed, as here) is not reproduced.

// cp1252High is the code page's 0x80..0x9F row (the five bytes it leaves
// undefined, 0x81 0x8D 0x8F 0x90 0x9D, map to the C1 controls of the same
// value, as Windows' table does).
var cp1252High = [32]rune{
	0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
	0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
	0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
	0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
}

var cp1252Reverse = func() map[rune]byte {
	m := make(map[rune]byte, len(cp1252High))
	for i, r := range cp1252High {
		m[r] = byte(0x80 + i)
	}
	return m
}()

// encodeCP1252 is WideCharToMultiByte(1252) on runes: one byte each.
func encodeCP1252(rs []rune) string {
	out := make([]byte, len(rs))
	for i, r := range rs {
		switch {
		case r < 0x80 || (r >= 0xA0 && r <= 0xFF):
			out[i] = byte(r)
		default:
			if b, ok := cp1252Reverse[r]; ok {
				out[i] = b
			} else {
				out[i] = '?'
			}
		}
	}
	return string(out)
}
