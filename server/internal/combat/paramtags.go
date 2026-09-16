package combat

// The engine addresses a character stat by a short ASCII tag packed into an
// integer, big-endian, and this file is the handful of those tags srrevamp's
// own comments name -- as constants, so the packed value is computed rather
// than transcribed.
//
// THAT IS THE WHOLE POINT. Hand-typing one of these has been wrong three times
// in this project, and a fourth time while recovering this very table (`str`
// typed as 7565170 when it is 0x737472 = 7566450, which turned a working probe
// into a silent zero result). A tag is a string; let the machine pack it.
//
// WHERE THE NAMES COME FROM. `MagicOption.txt` pairs each option's human code
// name with the packed tag it modifies, in its own columns 2 and 7 -- so the
// table names the tags itself, with no inference:
//
//	MATTR_INT        -> 'int'      MATTR_BLOCKRATE      -> 'bri'
//	MATTR_STR        -> 'str'      MATTR_CRITICAL       -> 'cri'
//	MATTR_HR         -> 'hr'       MATTR_EVADE_BLOCK    -> 'evbl'
//	MATTR_ER         -> 'er'       MATTR_EVADE_CRITICAL -> 'evcr'
//
// 53 distinct tags are named that way, and **every one of the 53 packed
// constants appears in the server binary**. The full table, with the item kind
// each option may appear on, is docs/protocol/magic_options.md.
//
// The same table confirms this file's opposition model from a direction it was
// not derived from. Its column 29 says which item kind carries each option:
//
//	MATTR_CRITICAL     weapon      MATTR_EVADE_CRITICAL  shield
//	MATTR_BLOCKRATE    shield      MATTR_EVADE_BLOCK     weapon
//
// Attacker's weapon carries critical and evade-block; defender's shield
// carries block and evade-critical. That is exactly the pairing
// MitigateDamage's note describes from the binary.
//
// AND IT DOES NOT OVERTURN "parry rate" / "attack rate". `MATTR_ER` sits on
// `armor` and `MATTR_HR` on `weapon`, which is the parry/attack-ratio pair the
// game displays -- so expanding ER to "evasion" would have been a wrong
// correction to a right comment. The initials are not the evidence; the item
// kind is.
const (
	TagStr      = "str"  // MATTR_STR,        on weapon/armor/shield/accessory
	TagInt      = "int"  // MATTR_INT,        likewise
	TagHP       = "hp"   // MATTR_HP,         on armor/helm/mail/pants
	TagMP       = "mp"   // MATTR_MP,         likewise
	TagHitRate  = "hr"   // MATTR_HR,         on weapon -- the attack ratio
	TagParry    = "er"   // MATTR_ER,         on armor  -- the parry ratio
	TagBlock    = "bri"  // MATTR_BLOCKRATE,  on shield
	TagCritical = "cri"  // MATTR_CRITICAL,   on weapon
	TagEvadeBlk = "evbl" // MATTR_EVADE_BLOCK,    on weapon, opposes TagBlock
	TagEvadeCri = "evcr" // MATTR_EVADE_CRITICAL, on shield, opposes TagCritical

	// The avatar variants, which are a SEPARATE family: they sit on avatar
	// (cosmetic) pieces, not on armour or weapons. They are here because
	// MitigateDamage's note names params 9 and 11 by these tags.
	TagAvatarParry   = "era" // MATTR_AVATAR_ER, on avatar_helm
	TagAvatarHitRate = "hra" // MATTR_AVATAR_HR, on avatar_mail
)

// PackTag encodes a stat tag the way the engine stores it: the ASCII bytes
// big-endian in a 32-bit word, so "cri" is 0x637269. Tags are at most four
// characters; a longer one would not fit the field and returns 0.
func PackTag(tag string) uint32 {
	if len(tag) == 0 || len(tag) > 4 {
		return 0
	}
	var v uint32
	for i := 0; i < len(tag); i++ {
		v = v<<8 | uint32(tag[i])
	}
	return v
}

// UnpackTag is PackTag's inverse, for reading a constant out of a disassembly.
// Returns "" for a word whose bytes are not all printable.
func UnpackTag(v uint32) string {
	var b []byte
	for shift := 24; shift >= 0; shift -= 8 {
		c := byte(v >> uint(shift))
		if c == 0 && len(b) == 0 {
			continue // leading padding
		}
		if c < 32 || c >= 127 {
			return ""
		}
		b = append(b, c)
	}
	return string(b)
}
