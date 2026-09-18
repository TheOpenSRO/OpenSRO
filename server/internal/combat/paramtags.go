package combat

// MaxMagicOptionsPerItem is 12: an item may carry at most twelve magic options.
//
// **Recovered 2026-09-17 from the engine's own assert**, which names the
// constant in words:
//
//	ReferenceData.cpp line 3011:
//	  "m_InstanceInfoOfItem.m_btMagParamNum < MAX_MAGPARAM_PER_ITEM"
//
// and compiles to a comparison against the literal:
//
//	6a9209  cmp BYTE PTR [esi+0x24],0xc
//	6a920d  jb  pass
//
// So the constant is 12, `m_btMagParamNum` is the count, and it lives at
// `+0x24` of the item's instance-info struct. The persisted counterpart is the
// _ITEMS column `MagParamNum` beside `MagParam`
// (docs/protocol/db_columns.md) -- the same quantity, stored.
//
// NOTHING IN srrevamp ENFORCES THIS YET. It has the tag vocabulary and no
// per-item option list to cap, so this is recorded for when it does rather
// than applied to something.
const MaxMagicOptionsPerItem = 12

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

// ParamFor maps a stat tag to the ParamKeeper param id the engine writes for
// it, recovered from Stat_ApplyTaggedModifier's disassembly.
//
// WHY THE DISASSEMBLY AND NOT THE DECOMPILATION. The dispatcher ends in
// `GObjPC::ParamKeeper_SetParam`, whose param id arrives in EDI -- a register
// Ghidra does not map to a parameter, so the C output shows every leaf as the
// identical `ParamKeeper_SetParam(0, param_3, value)` and cannot tell the tags
// apart at all. In the asm each leaf is `mov edi,N` immediately before the
// call, and the binding is plain.
//
// HOW IT WAS READ, and how it was checked. A walker binds each `cmp eax,TAG /
// je LEAF` to the param its leaf loads, following unconditional jumps. Six of
// the results were already known from unrelated work and are the control:
//
//	bri  -> 10   cri -> 12    from GObjMob_PublishStats' consecutive run
//	evbl -> 56   evcr -> 57   from Combat_ResolveDamage (see MitigateDamage)
//	str  -> 1    int  -> 2    from the damage pipeline's GetParam calls
//
// All six came back right, from a function none of them were derived from.
//
// THE RESIST FAMILY IS NOW SEPARATED (2026-09-18). It was left out because a
// walk exploring both arms of every branch reached all of 27, 29, 30, 31 and
// 32 from each tag -- an over-approximation, not a limit of the evidence.
// Reading each `je` target instead resolves them, because every leaf is
// reached by exactly one jump:
//
//	4987f5  mov edi,0x1e   <- 'bu'   30
//	4987fc  mov edi,0x1b + [esp+0x24]=0x1c   <- 'fz'   27 AND 28
//	498745  mov edi,0x1d   <- 'es'   29   (the fallthrough arm)
//	498824  mov edi,0x1f   <- 'ps'   31
//	49881d  mov edi,0x20   <- 'zb'   32
//
// 'bu' -> 30 is the control: the earlier conservative walk resolved it singly
// and this reading agrees. The block's extent is confirmed from the other end
// by 'rals' (MATTR_RESIST_ALL_SET), whose leaf at 0x498f46 writes params 27,
// 28, 29, 30, 31 and 32 in one consecutive run -- the game's own "resist all"
// enumerating the family. Six params, five tags, with 'fz' taking two.
//
// The other resists the dumper names -- disease, sleep, stun, fear, csmp --
// are the four-character 'rdii'/'rsli'/'soli'/'rfei'/'rcsi' tags and do NOT
// live in this range; where they go is not read.
var ParamFor = map[string]int{
	TagStr:           1,   // MATTR_STR
	TagInt:           2,   // MATTR_INT
	TagMP:            4,   // MATTR_MP
	TagBlock:         10,  // MATTR_BLOCKRATE
	TagCritical:      12,  // MATTR_CRITICAL
	TagAvatarHitRate: 11,  // MATTR_AVATAR_HR
	TagEvadeBlk:      56,  // MATTR_EVADE_BLOCK
	TagEvadeCri:      57,  // MATTR_EVADE_CRITICAL
	"hpa":            3,   // MATTR_AVATAR_HP
	"hpmp":           25,  // MATTR_REGENHPMP
	"hprg":           25,  // MATTR_AVATAR_HPRG
	"mprg":           26,  // MATTR_AVATAR_MPRG
	"mpna":           53,  // MATTR_NASRUN_MPNA
	"brna":           10,  // MATTR_NASRUN_BLOCKRATE -- the same param as 'bri'
	"drua":           128, // MATTR_AVATAR_DRUA
	"strj":           1,   // MATTR_STR_3JOB  -- Strength, like 'str'
	"strv":           1,   // MATTR_STR_AVATAR
	"intv":           2,   // MATTR_INT_AVATAR
	"rals":           27,  // MATTR_RESIST_ALL_SET -- writes 27..32; 27 is the first
	"bu":             30,  // MATTR_RESIST_BURN
	"fz":             27,  // anti-frostbite -- also writes 28, see SecondParamFor
	"es":             29,  // anti-eshock
	"ps":             31,  // anti-toxin
	"zb":             32,  // anti-zombie
}

// REGENERATION IS AN ITEM STAT, NOT A BASELINE ONE. Params 25 and 26 are
// written by MATTR_REGENHPMP, MATTR_AVATAR_HPRG and MATTR_AVATAR_MPRG, so the
// engine does have HP/MP regeneration parameters. That does not reopen the
// earlier finding that there is no passive regen: that finding was about what
// writes the pools by default, and nothing does. These params exist for items
// to grant, which is a different claim and a compatible one.

// BonusUnit says whether a magic option's number is an absolute amount or a
// percentage -- as the engine's own item dumper prints it.
//
// READ THIS AS A PROPERTY OF THE BONUS, NOT OF THE STAT. `block rate +%d` is
// flat because the option adds five POINTS; the underlying block rate is still
// a percentage. Taking "flat" here to mean "this stat is not a percentage"
// would be a misreading, and the distinction is exactly the sort that has cost
// this project time before.
//
// Recovered from two server-side debug formatters that print an item and its
// options in the game's own words -- `GObjPC::FUN_004909f0` (`0x004909f0`) and
// `FUN_00491bd0` (`0x00491bd0`). Each option line is a literal like
// `"block rate +%d"` or `"evcr +%d%%"`, guarded by the tag constant, so the
// tag, the label and the unit come out together.
//
// The two formatters are near-duplicates with different prefixes for the
// avatar family (`AVT` vs `Ava`), and they agree on every tag listed here.
//
// 'hp' IS DELIBERATELY ABSENT. The two formatters disagree about it --
// `0x004909f0` prints `"hp +%d%%"` and `0x00491bd0` prints `"hp +%d"` -- and
// both literals are really there, so this is a disagreement in the engine
// rather than a bad probe. Which one governs is not established, so neither
// ships.
var BonusUnit = map[string]string{
	TagStr:      "flat",    // "str +%d"
	TagInt:      "flat",    // "int +%d"
	TagMP:       "flat",    // "mp +%d"
	TagBlock:    "flat",    // "block rate +%d"  -- points onto a percentage stat
	TagCritical: "flat",    // "critical +%d"
	TagHitRate:  "percent", // "hr +%d%%"
	TagParry:    "percent", // "er +%d%%"
	TagEvadeBlk: "percent", // "evbl +%d%%"
	TagEvadeCri: "percent", // "evcr +%d%%"
}

// LabelFor is what the engine's own dumper calls each tag. Most print as the
// tag itself; these are the ones that do not, which is the useful part -- each
// is a tag whose meaning the spelling alone does not give.
//
// `dura` is the one worth noticing: it prints as **flaw**, and with a MINUS
// sign (`"flaw -%d%%"`), which is what `MATTR_DEC_MAXDUR` means -- a durability
// penalty, the only negative option in the table.
var LabelFor = map[string]string{
	TagBlock:    "block rate",
	TagCritical: "critical",
	"rein":      "reinforce",
	"dura":      "flaw", // negative: "flaw -%d%%"
	"hpmp":      "regen hpmp",
	// The resist family, in the engine's English. These give the five tags
	// their meanings even though the previous tick could not separate their
	// param ids -- a name and an id are different questions.
	"ps":   "anti-toxin",
	"fz":   "anti-frostbite",
	"bu":   "anti-burn",
	"es":   "anti-eshock",
	"zb":   "anti-zombie",
	"rsti": "resist stun",
	"rsli": "resist sleep",
	"rfei": "resist fear",
	"rdii": "resist disease",
	"rcsi": "resist csmp",
	// The bless family: only 'soli' prints as something other than itself.
	TagSolid: "solid",
}

// The BLESS family: the magic options that carry a probability as well as a
// value, and so fire by chance rather than applying flatly.
//
// The item dumper `FUN_00491bd0` (`0x00491bd0`) prints these four differently
// from every other option -- two numbers instead of one --
//
//	"ape(%d%%): %d"   "luck(%d%%): %d"   "solid(%d%%): %d"   "atha(%d%%): %d"
//
// reading the chance from the option record's `+0x14`, a field no other branch
// touches. **The set is closed and the binary says so**: any tag reaching that
// group and matching none of them falls through to
//
//	FUN_00425f70("unknown bless[%d]", tag);
//
// A fallback that names the concept is stronger evidence of a closed set than
// an enumeration is, because it shows the author expected nothing else.
//
// 'rep' (MATTR_REPAIR) sits in the same branch group and is NOT one of them: it
// prints `"rep: %d,"` with no chance, and with `value - 1` -- the stored number
// is one more than the one displayed. Recorded because an off-by-one in a
// display path is exactly the sort of thing that gets re-derived wrongly later.
const (
	TagAstral    = "ape"  // MATTR_APE
	TagLuck      = "luck" // MATTR_LUCK
	TagSolid     = "soli" // MATTR_SOLID
	TagAthanasia = "atha" // MATTR_ATHANASIA
	TagRepair    = "rep"  // MATTR_REPAIR -- same branch group, no chance
)

// BlessTags are the four options that roll a chance. srrevamp does not
// implement magic options, so nothing consumes this yet; it is here so that
// whoever does implement them does not model these four as unconditional.
var BlessTags = map[string]bool{
	TagAstral:    true,
	TagLuck:      true,
	TagSolid:     true,
	TagAthanasia: true,
}

// The per-item magic-option record, as two independent readers agree on it.
// The dumper walks the options printing `record+0x04` as the tag and
// `record+0x10` as the value, and the accessor `FUN_004927e0` (`0x004927e0`)
// returns `record+0x10` while writing `record+0x04` back through EDI. The
// bless branch adds `record+0x14`, the chance.
//
// The options live in a container at `GObjPC + 0x5c0` and are looked up rather
// than indexed, so there is no stride to record. An item carries at most
// MAX_MAGPARAM_PER_ITEM of them -- 12, from the client's own assert
// `"m_btMagicParamNum <= MAX_MAGPARAM_PER_ITEM"`.
const (
	MagicOptionTagOffset    = 0x04
	MagicOptionValueOffset  = 0x10
	MagicOptionChanceOffset = 0x14
	MaxMagicParamsPerItem   = 12
)


// SecondParamFor records the tags whose leaf writes a *second* param. The leaf
// sets the first id in EDI and stashes the second in [esp+0x24]; the shared
// tail writes the first, then writes the second if the stash is not -1.
//
//	4987fc  mov edi,0x1b                  ; first  -> 27
//	498801  mov DWORD PTR [esp+0x24],0x1c ; second -> 28
//	498809  jmp 0x498829                  ; the shared tail does both
var SecondParamFor = map[string]int{
	"fz": 28,
}

// ResistParams is the elemental resist run, enumerated by 'rals'
// (MATTR_RESIST_ALL_SET), whose leaf writes exactly these six in order.
var ResistParams = []int{27, 28, 29, 30, 31, 32}
