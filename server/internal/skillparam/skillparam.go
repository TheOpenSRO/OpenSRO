package skillparam

// Code is a skill-parameter code out of skilldata's Params column. The engine
// dispatches on them in SkillGlobal::RefSkill_ParseParams (0x00587630).
//
// HOW THE CODES WERE READ. Every `cmp reg,<imm>` in that function whose
// immediate decodes as two, three or four printable characters, big-endian --
// the same encoding as the stat tags, where decoding little-endian spells every
// code backwards.
//
// CORRECTED 2026-09-18: the codes are NOT all four characters. The first
// version of this file required exactly four and so published 156 codes,
// silently dropping 16 two-character and 15 three-character ones -- including
// 'att', the parameter this project's own export-refdata already reads a
// skill's damage from. That is the same class of error as the stat-tag table,
// which was published twice with four-character codes truncated to three: a
// length assumption baked into a decoder. There are 187 codes.
//
// HOW THE FIELDS WERE READ. Each code's `je` leads to a leaf that stores into
// the skill record. An early attempt walked a fixed window from each leaf and
// was withheld after a guard caught two codes resolving to one offset, because
// a leaf containing a loop ran into its neighbour. Each leaf is now bounded by
// the next leaf -- in a binary-search dispatcher every leaf is a `je` target --
// and with that bound there are no collisions at any code length.
//
// WHAT VALIDATES IT. Formulae::Formula_SkillPhysDamage was annotated in an
// earlier session, from a different function, as being called "when the skill
// carries 'pdmg' (skill+0x234)". This table, built without reference to that,
// puts 'pdmg' at 0x234.
//
// WHAT IS NOT CLAIMED is what a code MEANS. 'atca' and 'lkdh' are read as text;
// nothing here infers a semantic from the mnemonic.
type Code string

// PhysDamage carries a skill's physical damage; PhysDamageField is where it lands.
const (
	PhysDamage      Code = "pdmg"
	PhysDamageField      = 0x234
)

// Codes is every parameter code the parser recognises, in sorted order.
var Codes = []Code{
	"BDMD",
	"BLAT",
	"BSHP",
	"CBAT",
	"CBRA",
	"COAT",
	"DGHR",
	"DSCR",
	"DSER",
	"DTAT",
	"DTDR",
	"E1SA",
	"E2AA",
	"E2AH",
	"E2SA",
	"EAAT",
	"FIAT",
	"HLAT",
	"HLBP",
	"HLFS",
	"HLMD",
	"HLMI",
	"HLRU",
	"HLSM",
	"LIAT",
	"MAAT",
	"MUAT",
	"MUCR",
	"MUER",
	"RPBU",
	"RPDU",
	"RPTU",
	"SAAA",
	"STDU",
	"STSP",
	"TRAA",
	"WIMD",
	"WIRU",
	"abir",
	"abnb",
	"alcu",
	"apau",
	"apru",
	"atca",
	"att",
	"bbuf",
	"bgra",
	"bl",
	"bldr",
	"ca",
	"cbuf",
	"chcr",
	"cmcr",
	"cnsm",
	"cshp",
	"csit",
	"csmd",
	"csmp",
	"cspd",
	"cssr",
	"curt",
	"da",
	"dar",
	"dcmp",
	"dcri",
	"defp",
	"defr",
	"dgmp",
	"dmgr",
	"dmgt",
	"dn",
	"dru",
	"dru2",
	"ds",
	"dtnt",
	"dtt",
	"dttp",
	"dura",
	"efr",
	"efta",
	"eshp",
	"esht",
	"expi",
	"expu",
	"fb",
	"fitp",
	"gdr",
	"getv",
	"heal",
	"hide",
	"hitm",
	"hntp",
	"hpi",
	"hr",
	"hst2",
	"hst3",
	"hste",
	"hwir",
	"hwit",
	"inti",
	"irgc",
	"lfst",
	"lkag",
	"lkcp",
	"lkdr",
	"lks2",
	"lnks",
	"luck",
	"mc",
	"mcap",
	"mom",
	"mpi",
	"mscc",
	"msch",
	"msid",
	"msr",
	"mstc",
	"mwdt",
	"mwhh",
	"mwhs",
	"mwmh",
	"mwtt",
	"my",
	"nbuf",
	"nmf",
	"nmh",
	"odar",
	"onff",
	"ovl2",
	"pao",
	"pcdu",
	"pchr",
	"pdm2",
	"pdmg",
	"php1",
	"pmdg",
	"pmdp",
	"pmhp",
	"pmmp",
	"pmp1",
	"pola",
	"ps",
	"puls",
	"pw",
	"pwdt",
	"pwtt",
	"qest",
	"rcur",
	"real",
	"reat",
	"reqa",
	"reqc",
	"resu",
	"rhru",
	"rmut",
	"rpkt",
	"rt",
	"ru",
	"saps",
	"scls",
	"setv",
	"skc",
	"slcc",
	"spda",
	"spi",
	"ssou",
	"st",
	"stns",
	"stri",
	"summ",
	"tant",
	"tb",
	"tcmd",
	"tctc",
	"tel2",
	"tel3",
	"tele",
	"terd",
	"thld",
	"thrd",
	"tkss",
	"tnt2",
	"tpad",
	"tpdd",
	"tran",
	"trap",
	"zb",
}

// Field maps a code to the skill-record offset its leaf stores into. 3 codes
// are absent -- 'att', 'getv', 'setv' -- because their branches loop or dispatch further rather
// than storing directly, so a lookup here can miss even for a real code.
var Field = map[Code]int{
	"BDMD": 0x554,
	"BLAT": 0x530,
	"BSHP": 0x534,
	"CBAT": 0x510,
	"CBRA": 0x50c,
	"COAT": 0x4f0,
	"DGHR": 0x520,
	"DSCR": 0x550,
	"DSER": 0x54c,
	"DTAT": 0x528,
	"DTDR": 0x52c,
	"E1SA": 0x4d4,
	"E2AA": 0x4dc,
	"E2AH": 0x4e0,
	"E2SA": 0x4d8,
	"EAAT": 0x4ec,
	"FIAT": 0x4f4,
	"HLAT": 0x560,
	"HLBP": 0x56c,
	"HLFS": 0x564,
	"HLMD": 0x55c,
	"HLMI": 0x568,
	"HLRU": 0x558,
	"HLSM": 0x570,
	"LIAT": 0x4f8,
	"MAAT": 0x574,
	"MUAT": 0x540,
	"MUCR": 0x548,
	"MUER": 0x544,
	"RPBU": 0x508,
	"RPDU": 0x500,
	"RPTU": 0x504,
	"SAAA": 0x538,
	"STDU": 0x518,
	"STSP": 0x514,
	"TRAA": 0x53c,
	"WIMD": 0x4e4,
	"WIRU": 0x4e8,
	"abir": 0x3f8,
	"abnb": 0x41c,
	"alcu": 0x4b4,
	"apau": 0x2d8,
	"apru": 0x2d4,
	"atca": 0x3bc,
	"bbuf": 0x360,
	"bgra": 0x2f8,
	"bl":   0x444,
	"bldr": 0x58c,
	"ca":   0x458,
	"cbuf": 0x358,
	"chcr": 0x368,
	"cmcr": 0x36c,
	"cnsm": 0x2a0,
	"cshp": 0x46c,
	"csit": 0x460,
	"csmd": 0x468,
	"csmp": 0x470,
	"cspd": 0x464,
	"cssr": 0x45c,
	"curt": 0x40c,
	"da":   0x240,
	"dar":  0x26c,
	"dcmp": 0x2a8,
	"dcri": 0x42c,
	"defp": 0x25c,
	"defr": 0x260,
	"dgmp": 0x4cc,
	"dmgr": 0x418,
	"dmgt": 0x3dc,
	"dn":   0x44c,
	"dru":  0x3e4,
	"dru2": 0x3e8,
	"ds":   0x454,
	"dtnt": 0x3d0,
	"dtt":  0x420,
	"dttp": 0x424,
	"dura": 0x280,
	"efr":  0x294,
	"efta": 0x4b0,
	"eshp": 0x298,
	"esht": 0x29c,
	"expi": 0x3ec,
	"expu": 0x580,
	"fb":   0x310,
	"fitp": 0x578,
	"gdr":  0x4c8,
	"heal": 0x324,
	"hide": 0x428,
	"hitm": 0x2c8,
	"hntp": 0x48c,
	"hpi":  0x2ac,
	"hr":   0x24c,
	"hst2": 0x2bc,
	"hst3": 0x2c0,
	"hste": 0x2b8,
	"hwir": 0x4d0,
	"hwit": 0x588,
	"inti": 0x3f4,
	"irgc": 0x2d0,
	"lfst": 0x400,
	"lkag": 0x47c,
	"lkcp": 0x378,
	"lkdr": 0x478,
	"lks2": 0x374,
	"lnks": 0x370,
	"luck": 0x4b8,
	"mc":   0x288,
	"mcap": 0x4a8,
	"mom":  0x57c,
	"mpi":  0x2b0,
	"mscc": 0x4c0,
	"msch": 0x4a4,
	"msid": 0x4c4,
	"msr":  0x590,
	"mstc": 0x4bc,
	"mwdt": 0x3d8,
	"mwhh": 0x328,
	"mwhs": 0x404,
	"mwmh": 0x32c,
	"mwtt": 0x3c4,
	"my":   0x440,
	"nbuf": 0x35c,
	"nmf":  0x594,
	"nmh":  0x598,
	"odar": 0x270,
	"onff": 0x284,
	"ovl2": 0x37c,
	"pao":  0x350,
	"pcdu": 0x364,
	"pchr": 0x498,
	"pdm2": 0x238,
	"pdmg": 0x234,
	"php1": 0x348,
	"pmdg": 0x340,
	"pmdp": 0x344,
	"pmhp": 0x338,
	"pmmp": 0x33c,
	"pmp1": 0x34c,
	"pola": 0x304,
	"ps":   0x31c,
	"puls": 0x384,
	"pw":   0x2b4,
	"pwdt": 0x3d4,
	"pwtt": 0x3c0,
	"qest": 0x49c,
	"rcur": 0x414,
	"real": 0x300,
	"reat": 0x2fc,
	"reqa": 0x3b8,
	"reqc": 0x39c,
	"resu": 0x330,
	"rhru": 0x2a4,
	"rmut": 0x4ac,
	"rpkt": 0x2cc,
	"rt":   0x434,
	"ru":   0x250,
	"saps": 0x258,
	"scls": 0x380,
	"skc":  0x490,
	"slcc": 0x494,
	"spda": 0x264,
	"spi":  0x584,
	"ssou": 0x354,
	"st":   0x450,
	"stns": 0x448,
	"stri": 0x3f0,
	"summ": 0x308,
	"tant": 0x3c8,
	"tb":   0x474,
	"tcmd": 0x488,
	"tctc": 0x2c4,
	"tel2": 0x2f0,
	"tel3": 0x2f4,
	"tele": 0x2ec,
	"terd": 0x2dc,
	"thld": 0x484,
	"thrd": 0x2e0,
	"tkss": 0x3fc,
	"tnt2": 0x3cc,
	"tpad": 0x2e8,
	"tpdd": 0x2e4,
	"tran": 0x408,
	"trap": 0x4a0,
	"zb":   0x320,
}

// DrivesParams maps a skill-parameter code to the ParamKeeper params that
// parameter makes the applier write.
//
// HOW IT WAS READ. ApplySkillParamsToChar (0x00594ac0) is a run of guarded
// blocks -- `if (skill+off) { ... ParamKeeper_SetParam }` -- so the pairing is
// local to a block. The param id travels in EDI and is invisible in the C, so
// this is read from the asm, with each block bounded by the next skill-field
// reference so a walk cannot run into its neighbour. That function is a safe
// place to do it because it is provably a skill consumer: EngageSkill calls it,
// which is what rules out the struct-offset collisions that make a binary-wide
// sweep of these offsets useless.
//
// WHY IT IS TRUSTED. Five entries agree with facts recovered elsewhere, from
// different functions and before this table existed:
//
//	'stri' -> 1     Strength, the same param combat.ParamFor gives 'str'
//	'inti' -> 2     Intellect, likewise for 'int'
//	'hpi'  -> 3     the MaxHP chain head, likewise for 'hpa'
//	'mpi'  -> 4     the MaxMP chain head, likewise for 'mp'
//	'bgra' -> 27..32  exactly combat.ResistParams, the run 'rals' writes
//
// 'luck' and 'alcu' landing on 172 and 173 is a sixth: those are the two params
// CEnchant_Reinforce::GetSuccessRate and Enchant_SuccessRateBasePlusBonus read.
//
// A code driving SEVERAL params is not an error. 'bgra' writes the whole resist
// run, 'defp' both the physical and magical flat absorbs; that is what a
// parameter affecting a family looks like.
//
// WHAT IS NOT CLAIMED is the ARITHMETIC -- how the parameter's value becomes the
// param's, which slot it lands in, or how several contributors combine. Only
// which params a code touches is read.
var DrivesParams = map[Code][]int{
	"STSP": {23, 24},
	"alcu": {172},
	"apau": {13, 14, 15, 16},
	"apru": {13, 14, 15, 16},
	"bgra": {27, 28, 29, 30, 31, 32},
	"bldr": {198, 199, 200},
	"dar":  {132, 133, 134, 135},
	"dcmp": {141},
	"dcri": {57, 136, 137, 138, 139},
	"defp": {5, 6},
	"defr": {5, 6, 7, 8, 12},
	"dru":  {128, 129, 130, 131},
	"dru2": {128, 129, 130, 131},
	"expi": {185, 186},
	"expu": {186, 202},
	"gdr":  {182},
	"hide": {23, 24},
	"hpi":  {3},
	"hr":   {9, 11},
	"hst2": {23, 24},
	"hst3": {23, 24},
	"hste": {23, 24},
	"hwir": {184},
	"hwit": {195},
	"inti": {2},
	"irgc": {25, 26},
	"luck": {173},
	"mpi":  {4},
	"msid": {188},
	"msr":  {196, 197},
	"odar": {174, 175, 176, 177},
	"onff": {26},
	"pmdg": {178, 179},
	"pmdp": {5, 6},
	"pmhp": {3},
	"pmmp": {4},
	"reat": {145, 146, 147, 148, 149, 150},
	"rhru": {170, 171},
	"ru":   {33},
	"spda": {5, 13, 14},
	"spi":  {194},
	"stri": {1},
	"tant": {187},
	"terd": {9},
	"thrd": {11},
	"tpad": {13, 14},
	"tpdd": {5},
}

// Slot is which of a param's four accumulators a contribution lands in.
// GParamKeeper::ParamKeeper_EvaluateParam combines them as
//
//	value = base * (1 + pct/100) * mult * (scale/100)
//
// so the slot is half the arithmetic: it says whether a skill parameter adds a
// flat amount, a percentage, or a multiplier.
type Slot int

const (
	SlotBase  Slot = 0
	SlotPct   Slot = 1
	SlotMult  Slot = 2
	SlotScale Slot = 3
)

// Contribution is one param a skill parameter writes, and how.
type Contribution struct {
	Param int
	Slot  Slot
}

// Contributions maps a skill-parameter code to every (param, slot) pair
// ApplySkillParamsToChar writes for it. Read from the asm the same way as
// DrivesParams -- the slot is the first visible argument to
// ParamKeeper_SetParam, the last pushed immediate before the call.
//
// THE TABLE VALIDATES ITSELF STRUCTURALLY. The binary pairs a flat code with a
// ratio code over the same params:
//
//	'apau' -> params 13, 14, 15, 16 in SlotBase
//	'apru' -> params 13, 14, 15, 16 in SlotPct
//	'defp' -> params 5, 6 in SlotBase
//	'defr' -> params 5, 6 in SlotPct  (plus 7, 8, 12 in base)
//
// Two codes touching one set of params through different slots is what an
// absolute/percentage pair looks like, and nothing here had to assume it -- the
// slots were read, and the pairing fell out. A test asserts both pairs.
//
// STILL NOT CLAIMED: how the parameter's own value becomes the number written,
// and how several contributors to one slot combine. The slot is read; the
// arithmetic inside it is not.
var Contributions = map[Code][]Contribution{
	"STSP": {{23, 2}, {24, 2}},
	"alcu": {{172, 0}},
	"apau": {{13, 0}, {14, 0}, {15, 0}, {16, 0}},
	"apru": {{13, 1}, {14, 1}, {15, 1}, {16, 1}},
	"bgra": {{27, 0}, {28, 0}, {29, 0}, {30, 0}, {31, 0}, {32, 0}},
	"bldr": {{198, 0}, {199, 0}, {200, 0}},
	"dar":  {{132, 0}, {133, 0}, {134, 0}, {135, 0}},
	"dcmp": {{141, 0}},
	"dcri": {{57, 0}, {136, 0}, {137, 0}, {138, 0}, {139, 0}},
	"defp": {{5, 0}, {6, 0}},
	"defr": {{5, 1}, {6, 1}, {7, 0}, {8, 0}, {12, 0}, {12, 1}},
	"dru":  {{128, 0}, {129, 0}, {130, 0}, {131, 0}},
	"dru2": {{128, 0}, {129, 0}, {130, 0}, {131, 0}},
	"expi": {{185, 0}, {186, 0}},
	"expu": {{186, 0}, {202, 0}},
	"gdr":  {{182, 0}},
	"hide": {{23, 2}, {24, 2}},
	"hpi":  {{3, 0}, {3, 1}},
	"hr":   {{9, 0}, {9, 1}, {11, 0}, {11, 1}},
	"hst2": {{23, 2}, {24, 2}},
	"hst3": {{23, 2}, {24, 2}},
	"hste": {{23, 2}, {24, 2}},
	"hwir": {{184, 0}},
	"hwit": {{195, 0}},
	"inti": {{2, 0}},
	"irgc": {{25, 1}, {26, 1}},
	"luck": {{173, 0}},
	"mpi":  {{4, 0}, {4, 1}},
	"msid": {{188, 0}},
	"msr":  {{196, 0}, {197, 0}},
	"odar": {{174, 2}, {175, 2}, {176, 2}, {177, 2}},
	"onff": {{26, 3}},
	"pmdg": {{178, 2}, {179, 2}},
	"pmdp": {{5, 1}, {6, 1}},
	"pmhp": {{3, 1}},
	"pmmp": {{4, 1}},
	"reat": {{145, 0}, {146, 0}, {147, 0}, {148, 0}, {149, 0}, {150, 0}},
	"rhru": {{170, 0}, {171, 0}},
	"ru":   {{33, 0}},
	"spda": {{5, 0}, {13, 0}, {14, 0}},
	"spi":  {{194, 0}},
	"stri": {{1, 0}},
	"tant": {{187, 0}},
	"terd": {{9, 0}},
	"thrd": {{11, 0}},
	"tpad": {{13, 1}, {14, 1}},
	"tpdd": {{5, 1}},
}

// The two skill parameters Formulae::Formula_SkillPhysDamage takes as input,
// read at its call site inside Combat_ResolveDamage:
//
//	58f4e2  cmp DWORD PTR [ebx+0x234],0x0   ; the whole branch is gated on pdmg
//	58f4f0  mov eax,[ebx+0x538]             ; the bonus selector -> the implicit arg
//	58f4f6  mov ecx,[ebx+0x234]             ; the base           -> param_1
//	58f4ff  call 0x40f5f0                   ; Formula_SkillPhysDamage
//
// PhysDamage ('pdmg', skill+0x234) is the base: param_1 is a pointer and the
// formula's first act is `mov edi,[ecx]`, so the base is that record's first
// dword. PhysDamageBonus ('SAAA', skill+0x538) keys a lookup whose result adds
// its +0x4 field to the base before the level scaling.
//
// This is the third independent confirmation that 'pdmg' is 0x234: the branch
// walk that built Field, the annotation on Formula_SkillPhysDamage written in
// an earlier session, and now the call site itself.
const (
	PhysDamageBonus      Code = "SAAA"
	PhysDamageBonusField      = 0x538
)

// Combat_ResolveDamage chooses between TWO skill-damage formulas, and the
// choice is made on which parameter the skill carries:
//
//	58f4b5  cmp DWORD PTR [ebx+0x400],0x0   ; 'lfst' -- tried FIRST
//	58f4c3  je  0x58f4e2                    ; if absent, fall through
//	58f4d8  call 0x40f750                   ; Formula_SkillDamageCappedByHP
//	58f4e2  cmp DWORD PTR [ebx+0x234],0x0   ; 'pdmg'
//	58f4ff  call 0x40f5f0                   ; Formula_SkillPhysDamage
//
// AltDamage ('lfst') is the base of the first, with AltDamageBonus ('BSHP')
// keying its bonus and AltDamageExtra ('mwhs') adding a further term. That
// formula applies the same positive-level-difference gate as the physical one
// and then clamps its result against a participant's current HP (virtual slot
// 66, GetCurHP).
//
// WHAT THIS MEANS FOR srrevamp: it implements the 'pdmg' formula only. A skill
// carrying 'lfst' would take the other branch in the real engine and does not
// here. That is a missing branch, not a wrong constant, and it is recorded
// rather than approximated.
//
// What 'lfst', 'BSHP' and 'mwhs' MEAN is not read. They are named for their
// role in this formula and nothing is inferred from the mnemonics.
const (
	AltDamage           Code = "lfst"
	AltDamageField           = 0x400
	AltDamageExtra      Code = "mwhs"
	AltDamageExtraField      = 0x404
	AltDamageBonus      Code = "BSHP"
	AltDamageBonusField      = 0x534
)

// TimedEffectCodes are the eight skill parameters QueueTimedSkillEffect
// (0x00596960) groups into one timed effect. It tests all eight, and if any is
// set it allocates a record, copies all eight pointers into it at +0x14..+0x30,
// stamps GetTickCount() at +0x8 and queues it.
//
// THE TICK STAMP IS THE EVIDENCE. An effect applied immediately has no reason
// to record when it started; one that pays out on a clock does. That, plus the
// eight being read and copied as a unit, is why they are grouped here.
//
// NOT INFERRED FROM THE NAMES. Every one of the eight begins with 'p', which is
// suggestive and is not the reason they are grouped -- the grouping is the
// function reading and copying them together. What the 'p' stands for is not
// read.
//
// CORRECTION. An earlier note in this project called 'pmdg' "the magical
// counterpart" of 'pdmg', on the strength of the mnemonic and the two sitting
// near each other. That was wrong. 'pdmg' is dereferenced by
// Formula_SkillPhysDamage as a damage base; 'pmdg' is read by no damage formula
// at all -- its readers are ApplySkillParamsToChar and this function, which
// treats it as one of eight timed-effect parameters.
var TimedEffectCodes = []Code{
	"pmhp", // 0x338
	"pmmp", // 0x33c
	"pmdg", // 0x340
	"pmdp", // 0x344
	"php1", // 0x348
	"pmp1", // 0x34c
	"pao",  // 0x350
	"pcdu", // 0x364
}
