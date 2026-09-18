package skillparam

// The Param block: how a skill's parameter stream is laid out, and how far the
// parser moves for each code.
//
// RECOVERED 2026-09-18 from SkillGlobal::RefSkill_ParseParams (0x00587630) in
// SR_GameServer.exe, by walking its dispatch tree and reading, for each code,
// the field it stores into and the amount it advances the cursor.
//
// WHAT THE PARSER ACTUALLY DOES, which is not what an earlier reading assumed.
// A code's field does NOT receive the parameter's value. It receives a POINTER
// into the stream, just past the code word:
//
//	00587a4b  mov [esi+0x434],eax      ; eax = cursor + 1, i.e. the values
//	add DAT_00c826bc,4                 ; cursor advances by the run
//
// So Field[code] says where the engine remembers the run, and Run[code] says
// how long the run is. Reading a value needs both.
//
// THREE STRUCTURAL FACTS, each of which bounds the table and would fail loudly
// if the extraction were wrong:
//
//   - The prologue is memset(skill+0x230, 0, 0x37c), so every field the parser
//     writes lies in [0x230, 0x5ac). All 186 do.
//   - The cursor starts at skill+0x16c and is a uint*, so every advance is in
//     32-bit words, not bytes.
//   - The loop ends on `if (0x31 < index) return`, capping the block at 50
//     words -- which is independently what refdata.Skill calls "the 50 generic
//     Param slots".
//
// The dispatch tree is exhaustive: the last code tested is 'trap', and its
// miss path is the parser's own error, "unknown skill param!!! [RefSkill ID:
// %d, ParamValue: %d]". Nothing falls through silently.
//
// MEASURED AGAINST REAL DATA. Walking all 33,632 rows of the seven skilldata
// shards in a real Media.pk2 with this table: **every row walks to completion**
// -- 33,340 to the natural end of the block and 292 to the 'ssou' terminator --
// with zero unrecognised codes. (It was 96.2% until the 19 markers were
// reclassified from KindVarLen to run-1; see KindMarker.) A wrong run length
// anywhere derails the rest of a row, so 33,632 clean traversals are that many
// independent confirmations of every length they touch.

// ParamKind is how the parser consumes a run.
type ParamKind int

const (
	// KindFixed: the parser states the run length. Run[code] is it.
	KindFixed ParamKind = iota
	// KindMarker: the parser advances exactly ONE word -- past the code word --
	// and points the field at the run that FOLLOWS, then continues the loop.
	// So a marker carries no values of its own; the field is a bookmark into the
	// rest of the stream, and the following (code, value) runs are walked by the
	// same loop. Run is 1.
	//
	// CORRECTED 2026-09-18: these were KindVarLen, "a walk cannot continue past
	// one of these". That was wrong for 19 of the 20. The parser does not stop
	// at them and neither should a walk: reclassified as run-1 markers, EVERY
	// one of the 33,632 real skill rows walks to completion with zero
	// unrecognised codes (was 96.2%). The one real stopper is the terminator.
	KindMarker
	// KindTerminator: the parser stores the field and RETURNS -- this code is
	// always the last in the block. Only 'ssou' is one (it has a `return;` in
	// its branch where every other code falls through to the loop). A walk that
	// reaches it is COMPLETE, not blocked. Run is 1.
	KindTerminator
	// KindArray: the run fills the next free slot of a fixed-size array, so the
	// code may legitimately appear several times in one block.
	KindArray
	// KindPrefix: a SECOND word selects the parameter. Only 'getv' is one; its
	// 40 sub-codes are in GetvSub.
	KindPrefix
)

// ParamBlockColumn is the 0-based index of a skilldata row's first Param word
// -- column 70 counting from 1.
//
// CORRECTED 2026-09-18, and this is the correction that mattered most.
// docs/protocol/skill_params.md said column 69, and under that alignment only
// 21,385 of 33,632 rows walked to the end: 11,907 stopped immediately, reading
// a neighbouring column's value (1, 3 or 4) as a code. Shifting by one column
// takes the walk to 32,367 with zero unrecognised codes. 'att' sits at column
// 70 in 29,312 rows and is the first code of the block in all of them.
const ParamBlockColumn = 69

// ParamBlockMaxWords is the cap the parser's own loop enforces.
const ParamBlockMaxWords = 50

// The region the parser clears and then fills with pointers, and the field the
// stream itself starts at.
const (
	ParsedRegionStart = 0x230
	ParsedRegionLen   = 0x37c
	StreamField       = 0x16c
)

// Run is the run length in 32-bit WORDS, including the code word, so a run of 6
// carries 5 values. Markers and the terminator are run 1 (code word only).
var Run = map[Code]int{
	"att":  6,
	"pdmg": 2,
	"pdm2": 2,
	"ko":   3,
	"da":   2,
	"cr":   3,
	"ck":   2,
	"hr":   3,
	"ru":   2,
	"kb":   3,
	"saps": 3,
	"defp": 4,
	"defr": 3,
	"spda": 3,
	"ar":   3,
	"dar":  3,
	"odar": 3,
	"br":   3,
	"er":   3,
	"dura": 2,
	"onff": 3,
	"mc":   3,
	"efr":  7,
	"esht": 3,
	"cnsm": 4,
	"rhru": 3,
	"dcmp": 2,
	"hpi":  3,
	"mpi":  3,
	"pw":   5,
	"hste": 2,
	"hst2": 2,
	"hst3": 2,
	"irgc": 3,
	"apru": 3,
	"apau": 3,
	"terd": 2,
	"thrd": 2,
	"tpdd": 2,
	"tpad": 2,
	"tele": 3,
	"tel2": 3,
	"tel3": 3,
	"bgra": 3,
	"reat": 3,
	"real": 4,
	"pola": 3,
	"summ": 6,
	"fz":   3,
	"fb":   3,
	"es":   4,
	"bu":   4,
	"ps":   4,
	"zb":   3,
	"heal": 5,
	"mwhh": 2,
	"mwmh": 2,
	"resu": 3,
	"cura": 2,
	"pmhp": 5,
	"pmmp": 5,
	"pmdg": 5,
	"pmdp": 5,
	"pao":  2,
	"pcdu": 3,
	"chcr": 2,
	"cmcr": 2,
	"lnks": 5,
	"lkcp": 2,
	"ovl2": 2,
	"scls": 2,
	"puls": 2,
	"reqc": 2,
	"reqa": 2,
	"atca": 3,
	"pwtt": 2,
	"mwtt": 2,
	"tant": 3,
	"tnt2": 3,
	"dtnt": 3,
	"pwdt": 2,
	"mwdt": 2,
	"dmgt": 3,
	"lkdh": 4,
	"dru":  3,
	"dru2": 3,
	"expi": 3,
	"stri": 3,
	"inti": 3,
	"abir": 3,
	"tkss": 2,
	"lfst": 2,
	"mwhs": 2,
	"tran": 3,
	"curt": 3,
	"curl": 4,
	"rcur": 2,
	"dmgr": 5,
	"abnb": 2,
	"dtt":  3,
	"dttp": 3,
	"hide": 4,
	"dcri": 2,
	"se":   4,
	"rt":   4,
	"sl":   4,
	"fe":   4,
	"my":   5,
	"bl":   6,
	"stns": 4,
	"dn":   5,
	"st":   4,
	"ds":   5,
	"ca":   4,
	"cssr": 5,
	"csit": 5,
	"cspd": 5,
	"csmd": 5,
	"cshp": 7,
	"csmp": 7,
	"tb":   5,
	"lkdr": 4,
	"lkag": 3,
	"lkdd": 2,
	"thld": 2,
	"tcmd": 3,
	"skc":  4,
	"pchr": 2,
	"qest": 5,
	"msch": 3,
	"mcap": 3,
	"rmut": 2,
	"alcu": 2,
	"luck": 2,
	"mstc": 2,
	"mscc": 2,
	"msid": 2,
	"gdr":  2,
	"dgmp": 2,
	"hwir": 2,
	"mom":  5,
	"expu": 3,
	"spi":  2,
	"hwit": 2,
	"bldr": 4,
	"msr":  3,
	"setv": 4,
	"reqi": 3,
	// 'getv' has no advance of its own: each of its 40 sub-branches advances,
	// and all 40 advance by 2. So the run is 2 -- the code word and the
	// sub-code -- and the sub-code is the value.
	"getv": 2,
	// The 19 markers and the one terminator all advance exactly one word (the
	// code) and carry no values; their field is a bookmark into the runs that
	// follow. 'ssou' additionally makes the parser return.
	"ao":   1,
	"bbuf": 1,
	"cbuf": 1,
	"efta": 1,
	"eshp": 1,
	"fitp": 1,
	"hitm": 1,
	"hntp": 1,
	"lks2": 1,
	"nbuf": 1,
	"nmf":  1,
	"nmh":  1,
	"php1": 1,
	"pmp1": 1,
	"reqn": 1,
	"rpkt": 1,
	"slcc": 1,
	"tctc": 1,
	"trap": 1,
	"ssou": 1,
}

// Kind classifies every top-level code. There are 169: 146 fixed-run, 19
// markers, 1 terminator ('ssou'), 2 arrays and the one two-word prefix.
var Kind = map[Code]ParamKind{
	"att":  KindFixed,
	"pdmg": KindFixed,
	"pdm2": KindFixed,
	"ko":   KindFixed,
	"da":   KindFixed,
	"cr":   KindFixed,
	"ck":   KindFixed,
	"hr":   KindFixed,
	"ru":   KindFixed,
	"kb":   KindFixed,
	"saps": KindFixed,
	"defp": KindFixed,
	"defr": KindFixed,
	"spda": KindFixed,
	"ar":   KindFixed,
	"dar":  KindFixed,
	"odar": KindFixed,
	"br":   KindFixed,
	"er":   KindFixed,
	"dura": KindFixed,
	"onff": KindFixed,
	"mc":   KindFixed,
	"efr":  KindFixed,
	"esht": KindFixed,
	"cnsm": KindFixed,
	"rhru": KindFixed,
	"dcmp": KindFixed,
	"hpi":  KindFixed,
	"mpi":  KindFixed,
	"pw":   KindFixed,
	"hste": KindFixed,
	"hst2": KindFixed,
	"hst3": KindFixed,
	"irgc": KindFixed,
	"apru": KindFixed,
	"apau": KindFixed,
	"terd": KindFixed,
	"thrd": KindFixed,
	"tpdd": KindFixed,
	"tpad": KindFixed,
	"tele": KindFixed,
	"tel2": KindFixed,
	"tel3": KindFixed,
	"bgra": KindFixed,
	"reat": KindFixed,
	"real": KindFixed,
	"pola": KindFixed,
	"summ": KindFixed,
	"fz":   KindFixed,
	"fb":   KindFixed,
	"es":   KindFixed,
	"bu":   KindFixed,
	"ps":   KindFixed,
	"zb":   KindFixed,
	"heal": KindFixed,
	"mwhh": KindFixed,
	"mwmh": KindFixed,
	"resu": KindFixed,
	"cura": KindFixed,
	"pmhp": KindFixed,
	"pmmp": KindFixed,
	"pmdg": KindFixed,
	"pmdp": KindFixed,
	"pao":  KindFixed,
	"pcdu": KindFixed,
	"chcr": KindFixed,
	"cmcr": KindFixed,
	"lnks": KindFixed,
	"lkcp": KindFixed,
	"ovl2": KindFixed,
	"scls": KindFixed,
	"puls": KindFixed,
	"reqc": KindFixed,
	"reqa": KindFixed,
	"atca": KindFixed,
	"pwtt": KindFixed,
	"mwtt": KindFixed,
	"tant": KindFixed,
	"tnt2": KindFixed,
	"dtnt": KindFixed,
	"pwdt": KindFixed,
	"mwdt": KindFixed,
	"dmgt": KindFixed,
	"lkdh": KindFixed,
	"dru":  KindFixed,
	"dru2": KindFixed,
	"expi": KindFixed,
	"stri": KindFixed,
	"inti": KindFixed,
	"abir": KindFixed,
	"tkss": KindFixed,
	"lfst": KindFixed,
	"mwhs": KindFixed,
	"tran": KindFixed,
	"curt": KindFixed,
	"curl": KindFixed,
	"rcur": KindFixed,
	"dmgr": KindFixed,
	"abnb": KindFixed,
	"dtt":  KindFixed,
	"dttp": KindFixed,
	"hide": KindFixed,
	"dcri": KindFixed,
	"se":   KindFixed,
	"rt":   KindFixed,
	"sl":   KindFixed,
	"fe":   KindFixed,
	"my":   KindFixed,
	"bl":   KindFixed,
	"stns": KindFixed,
	"dn":   KindFixed,
	"st":   KindFixed,
	"ds":   KindFixed,
	"ca":   KindFixed,
	"cssr": KindFixed,
	"csit": KindFixed,
	"cspd": KindFixed,
	"csmd": KindFixed,
	"cshp": KindFixed,
	"csmp": KindFixed,
	"tb":   KindFixed,
	"lkdr": KindFixed,
	"lkag": KindFixed,
	"lkdd": KindFixed,
	"thld": KindFixed,
	"tcmd": KindFixed,
	"skc":  KindFixed,
	"pchr": KindFixed,
	"qest": KindFixed,
	"msch": KindFixed,
	"mcap": KindFixed,
	"rmut": KindFixed,
	"alcu": KindFixed,
	"luck": KindFixed,
	"mstc": KindFixed,
	"mscc": KindFixed,
	"msid": KindFixed,
	"gdr":  KindFixed,
	"dgmp": KindFixed,
	"hwir": KindFixed,
	"mom":  KindFixed,
	"expu": KindFixed,
	"spi":  KindFixed,
	"hwit": KindFixed,
	"bldr": KindFixed,
	"msr":  KindFixed,
	"ao":   KindMarker,
	"eshp": KindMarker,
	"tctc": KindMarker,
	"hitm": KindMarker,
	"rpkt": KindMarker,
	"php1": KindMarker,
	"pmp1": KindMarker,
	"ssou": KindTerminator,
	"cbuf": KindMarker,
	"nbuf": KindMarker,
	"bbuf": KindMarker,
	"lks2": KindMarker,
	"reqn": KindMarker,
	"hntp": KindMarker,
	"slcc": KindMarker,
	"trap": KindMarker,
	"efta": KindMarker,
	"fitp": KindMarker,
	"nmf":  KindMarker,
	"nmh":  KindMarker,
	"setv": KindArray,
	"reqi": KindArray,
	"getv": KindPrefix,
}

// GetvSub is the sub-vocabulary of the two-word 'getv' parameter: the second
// word selects which field the run fills. Every one of them is a run of 2, so
// the value IS the sub-code and 'getv' always advances two words.
//
// These 40 were the bulk of what docs/protocol/skill_params.md recorded as an
// open lead -- "roughly 55 further tag comparisons ... whether the vocabulary
// is really ~105 or ~145 is open". It is 209: 169 top-level codes and these.
var GetvSub = map[Code]int{
	"E1SA": 0x4d4,
	"E2SA": 0x4d8,
	"E2AA": 0x4dc,
	"E2AH": 0x4e0,
	"WIMD": 0x4e4,
	"WIRU": 0x4e8,
	"EAAT": 0x4ec,
	"COAT": 0x4f0,
	"FIAT": 0x4f4,
	"LIAT": 0x4f8,
	"RPDU": 0x500,
	"RPTU": 0x504,
	"RPBU": 0x508,
	"CBRA": 0x50c,
	"CBAT": 0x510,
	"STSP": 0x514,
	"STDU": 0x518,
	"DGAT": 0x51c,
	"DGHR": 0x520,
	"DGAA": 0x524,
	"DTAT": 0x528,
	"DTDR": 0x52c,
	"BLAT": 0x530,
	"BSHP": 0x534,
	"SAAA": 0x538,
	"TRAA": 0x53c,
	"MUAT": 0x540,
	"MUER": 0x544,
	"MUCR": 0x548,
	"DSER": 0x54c,
	"DSCR": 0x550,
	"BDMD": 0x554,
	"HLRU": 0x558,
	"HLMD": 0x55c,
	"HLAT": 0x560,
	"HLFS": 0x564,
	"HLMI": 0x568,
	"HLBP": 0x56c,
	"HLSM": 0x570,
	"MAAT": 0x574,
}

// EfrField: 'efr' picks its target field from its FIRST VALUE rather than
// having one. A value outside this set is parsed and discarded -- the cursor
// still advances the full 7 words.
//
// This is why skillparam.Field carried 0x294 for 'efr' while a second reading
// of the same branch produced 0x28c: both are real, and neither is the whole
// code. It is also why the code looked variable-length and was reported as the
// most common thing stopping a walk; it is a fixed run of 7.
var EfrField = map[int]int{
	1: 0x28c,
	2: 0x290,
	3: 0x294,
}

// The two array parameters, each scanning its slots for the first empty one and
// asserting when full.
const (
	SetvArrayBase  = 0x388
	SetvArraySlots = 5
	ReqiArrayBase  = 0x3a0
	ReqiArraySlots = 5
)

// Entry is one run a walk consumed.
type Entry struct {
	Code  Code
	Index int // word index of the CODE word within the block
	Run   int // words consumed, including the code word
}

// CodeOf decodes a stored Param word into its code. The codes are C
// multi-character literals held big-endian, so the leading zero bytes are
// padding and the remaining bytes are the letters in order. Reading the stored
// integer little-endian spells every code backwards, which has produced a wrong
// answer in this project twice; this is the direction that is right.
func CodeOf(w int32) Code {
	var b [4]byte
	b[0] = byte(w >> 24)
	b[1] = byte(w >> 16)
	b[2] = byte(w >> 8)
	b[3] = byte(w)
	i := 0
	for i < 4 && b[i] == 0 {
		i++
	}
	return Code(b[i:])
}

// Walk parses a skill's Param block the way the engine does: each run is a code
// word followed by Run[code]-1 values, and a zero word is padding to skip.
//
// It returns the runs it consumed, and reports complete=false with the code
// that stopped it. A walk stops for exactly two reasons, and they mean
// different things:
//
//   - the 'ssou' terminator, which the parser returns at -- a COMPLETE walk;
//   - a word that is no code at all, which IS an error and means either the
//     block does not start where the caller thinks it does or the table is
//     wrong. Across all 33,632 real rows this does not happen.
//
// Markers (KindMarker) do NOT stop a walk: they advance one word and the loop
// continues, exactly as the parser does.
//
// Callers that only need to locate one parameter should prefer Find, which says
// what to do about an incomplete walk.
func Walk(words []int32) (entries []Entry, stopped Code, complete bool) {
	for i := 0; i < len(words) && i < ParamBlockMaxWords; {
		if words[i] == 0 {
			i++
			continue
		}
		c := CodeOf(words[i])
		run, ok := Run[c]
		if !ok || run < 1 {
			// A word that is no code at all: the block does not start where the
			// caller thinks, or the table is wrong. Across all 33,632 real rows
			// this does not happen at ParamBlockColumn.
			return entries, c, false
		}
		entries = append(entries, Entry{Code: c, Index: i, Run: run})
		if Kind[c] == KindTerminator {
			// The parser returns here; this run is the last in the block. The
			// walk is COMPLETE, not blocked.
			return entries, "", true
		}
		i += run
	}
	return entries, "", true
}

// Find returns the word index of the first run carrying code, and whether the
// walk that looked for it finished. A caller that gets found=false and
// complete=false learned nothing -- the code may sit past where the walk
// stopped -- and should fall back rather than conclude the skill lacks it.
func Find(words []int32, code Code) (index int, found bool, complete bool) {
	entries, _, complete := Walk(words)
	for _, e := range entries {
		if e.Code == code {
			return e.Index, true, complete
		}
	}
	return 0, false, complete
}

// CombatParameters is the engine's own test for "does this skill do anything in
// combat", read off Formulae's Combat_ResolveDamage (0x0058e5f0).
//
// The function opens with a 33-way test of the skill record, every term of the
// form `*(int *)(skill + <field>) == 0`. Read through Field it is exactly this
// list of parameter codes, which is what makes it a vocabulary question rather
// than a wall of offsets:
//
//	if (!att && !ck) {
//	    if (none of the other 31 are set) {
//	        if (!efr)                      return;   // no blow at all
//	        if (efr.values[1] != 6)        return;
//	    }
//	    local_d0 = 1;
//	}
//
// WHAT THIS CONFIRMS INDEPENDENTLY. 32 of the 33 offsets resolve against Field,
// and the 33rd is 'efr' at 0x28c, which Field records under a different one of
// efr's three fields. Combat_ResolveDamage played no part in building Field, so
// this is a second function agreeing with it on 33 offsets at once. Three
// further agreements fall out of the same function: skill+0x230 is dereferenced
// and masked with 4, which is the physical bit of the damage-type mask that
// combat.AttackType already reads out of 'att' value[0]; skill+0x288 is read as
// the pair (2, N), which is exactly what export-refdata's hitCountParam takes
// from 'mc'; and skill+0x230's value[4] is read, so 'att' really does carry
// five values and not four.
//
// WHAT IT MEANS, AND THE PART THAT IS NOT READ. A skill carrying none of these
// and no qualifying 'efr' makes the function RETURN -- it resolves no blow at
// all. That is an unconditional return and is settled. What local_d0 = 1 leads
// to when the function does continue is NOT settled here: it gates the
// Formula_MitigatePhysicalDamage call as well as the damage floor, and the
// branches it selects instead have not been read. So "a skill with no attack
// parameter deals nothing" is proven only for the early-return case, and is not
// claimed for the rest.
//
// MEASURED. Of the 32,367 real skill rows that walk cleanly, 1,813 carry none
// of these 33; 16 of those carry 'efr' with value[1] == 6 and survive, and
// **1,797 (5.6%) take the early return**.
var CombatParameters = []Code{
	"att", "pdmg", "pdm2", "ck", "fz", "fb", "es", "bu", "ps", "zb",
	"tant", "tnt2", "dtnt", "lfst", "dttp", "se", "rt", "sl", "fe", "my",
	"bl", "dn", "st", "ds", "ca", "cssr", "csit", "cspd", "csmd", "cshp",
	"csmp", "tb", "efr",
}

// EfrCombatSelector is the value 'efr' must carry as its SECOND value for a
// skill with no other combat parameter to resolve a blow at all:
// `if (*(int *)(efr + 4) != 6) return;`.
//
// The 6 is now read: 'efr' value[1] is a targeting MODE, and mode 6 is an area
// effect that applies to every entry of the skill's target vector -- so a skill
// carrying only 'efr' in mode 6 does land a blow, on each area target. The same
// field+offset is read as a mode by FUN_00593f50 (the skill-effect applier
// called by EngageSkill), which special-cases modes 6 and 7; the two functions
// share no call path, which is what grounds it. See docs/protocol/skill_params.md,
// "efr is a targeting mode". srrevamp has no area-targeting path, so this is the
// citation for the constant rather than something wired in.
const EfrCombatSelector = 6

// EfrModeOffset is where the mode sits within the 'efr' run: value[1], i.e. +4
// from the field pointer (which points at value[0], the field selector).
const EfrModeOffset = 4

// CarriesCombatParameter reports whether a skill's Param block carries any of
// the parameters Combat_ResolveDamage tests before it will resolve a blow.
//
// decided says whether the answer is trustworthy. Finding one settles it
// immediately, even if the rest of the block cannot be walked. Finding none
// settles it only when the walk finished: a variable-length code hides whatever
// follows it, and a caller must not read "none found" as "this skill has none".
//
// 'efr' counts only when its SECOND value is EfrCombatSelector, which is the
// engine's own extra condition:
//
//	if (!efr)                       return;
//	if (*(int *)(efr + 4) != 6)     return;
func CarriesCombatParameter(words []int32) (carries, decided bool) {
	combat := make(map[Code]bool, len(CombatParameters))
	for _, c := range CombatParameters {
		combat[c] = true
	}
	entries, _, complete := Walk(words)
	for _, e := range entries {
		if !combat[e.Code] {
			continue
		}
		if e.Code == "efr" {
			// values start at e.Index+1, so the second value is +2.
			if e.Index+2 < len(words) && words[e.Index+2] == EfrCombatSelector {
				return true, true
			}
			continue
		}
		return true, true
	}
	return false, complete
}

// DamageParameters are the two parameters that decide whether a skill's blow is
// computed at all, as opposed to merely whether the function runs.
//
// Combat_ResolveDamage (0x0058e5f0) sets its `local_d0` flag from exactly these
// two, and `local_d0` then selects between computing the blow and zeroing it:
//
//	if ((skill[0x230] == 0) && (skill[0x248] == 0)) { ... local_d0 = 1; }
//
//	case 0:                                   // the ordinary damage kind
//	  if (local_d0 == 0) {
//	      result[0x28] = Formula_MitigatePhysicalDamage(...);
//	      result[0x24] = Formula_MitigateMagicalDamage(...);
//	  } else {
//	      result[0x28] = 0;                   // physical
//	      result[0x24] = 0;                   // magical
//	  }
//	  result[0x20] = result[0x28] + result[0x24];
//
// So a skill carrying neither 'att' nor 'ck' deals **zero**: both halves are
// written zero and the total is their sum. This is a wider rule than the early
// return CombatParameters describes -- that one decides whether a blow is
// resolved at all, this one decides whether a resolved blow has any damage in
// it -- and the first is a strict subset of the second.
//
// SCOPED TO THE ORDINARY DAMAGE KIND. The switch is on a byte of the hit record
// that is left 0 unless one of four conditions sets it to 1..4, and only case 0
// consults local_d0; the others compute damage by other means
// (Formula_RollLevelDamage, a fixed 1, two singleton lookups). What selects
// those kinds has not been read, so this rule is stated for the default kind
// and not claimed for all four.
//
// MEASURED over the 32,367 real skill rows that walk cleanly: 29,884 carry
// 'att', **exactly one** carries 'ck', and **2,482 carry neither**. Of those
// 2,482, 1,813 also carry none of CombatParameters and take the earlier return;
// the other 669 resolve a blow of zero.
var DamageParameters = []Code{"att", "ck"}

// DealsZeroDamage reports whether Combat_ResolveDamage's `local_d0` would be 1
// for this skill: it carries neither of DamageParameters, so the ordinary
// damage kind writes zero to both halves of the blow.
//
// decided carries the same meaning as in CarriesCombatParameter: finding one of
// the two settles it, finding neither settles it only when the walk finished.
func DealsZeroDamage(words []int32) (zero, decided bool) {
	entries, _, complete := Walk(words)
	for _, e := range entries {
		for _, d := range DamageParameters {
			if e.Code == d {
				return false, true
			}
		}
	}
	return true, complete
}

// WordOf is CodeOf's inverse: the 32-bit word a code is stored as. A caller
// holding a whole skilldata row can use it for the one inference about a Param
// block that needs no walk at all -- if a code's word appears NOWHERE in the
// row, the block cannot carry that parameter. The converse is not sound (the
// same integer could be some other column's value), so only absence is proof.
func WordOf(c Code) int32 {
	var w int32
	for _, b := range []byte(c) {
		w = w<<8 | int32(b)
	}
	return w
}

// The two bits of 'att' value[0] that gate the mitigation formulas. Each
// formula's first test returns 0 outright when its bit is clear:
//
//	Formula_MitigatePhysicalDamage  if ((**(byte **)(skill + 0x230) & 4) == 0) return 0;
//	Formula_MitigateMagicalDamage   if ((**(byte **)(skill + 0x230) & 8) == 0) return 0;
const (
	AttPhysicalBit = 4
	AttMagicalBit  = 8
)

// BlowIsFloor reports whether every blow this skill lands on the ordinary
// damage kind is exactly the engine's floor of 1.
//
// That happens when `local_d0` is 0 -- the skill carries 'att' or 'ck', so the
// blow IS computed -- but the computation is identically zero, because
// Combat_ResolveDamage then floors it:
//
//	if (total == 0) { if (local_d0 == 0) { total = 1; } ... }
//
// There are three ways to be identically zero, each read off the formulas:
//
//   - no 'att' at all (a 'ck'-only skill): both formulas open with
//     `if (skill[0x230] == 0) return 0`;
//   - 'att' whose value[0] has neither AttPhysicalBit nor AttMagicalBit: each
//     formula returns 0 at its own bit test;
//   - 'att' whose percent, value[1], is 0: the formulas compute
//     `damage = percent * damage / 100` with no guard around a zero, and every
//     later term is proportional to that damage.
//
// The flat min/max cannot rescue the third case: they join the roll BEFORE the
// multiply. In the real table the question does not even arise -- all 440 rows
// with a zero percent carry a zero min and max.
//
// MEASURED over all 33,632 real rows: 440 carry 'att' with a percent of 0 (420
// of them the mall pets' cold, fire and lightning skills), 5 more carry a
// percent but neither damage bit, and 1 carries 'ck' alone. 446 in all.
//
// hasAtt, attType and attPercent describe the row's 'att' run; carriesCk says
// whether it carries 'ck'. A skill with neither parameter is not a floor blow,
// it is a zero one -- see DealsZeroDamage.
func BlowIsFloor(hasAtt bool, attType, attPercent int32, carriesCk bool) bool {
	if !hasAtt {
		return carriesCk
	}
	if attType&(AttPhysicalBit|AttMagicalBit) == 0 {
		return true
	}
	return attPercent == 0
}

// The healing-received buff chain, three recovered pieces that meet at two
// ParamKeeper params.
//
// A heal's size is scaled by (1 + GetParam(id)/100) -- see docs/protocol/heal.md
// and Skill_ApplyHealToObject (0x005a0850) -- with these two ids, read from the
// HEALED object's keeper:
const (
	HealHPScaleParam = 170 // 0xaa, scales the HP half of a heal
	HealMPScaleParam = 171 // 0xab, scales the MP half
)

// HealScaleBuffCode is the skill parameter that GRANTS those two params. Its
// write site is in ApplySkillParamsToChar (0x00594ac0): the 'rhru' field
// (skill+0x2a4) value[0] -> param 170 and value[1] -> param 171, both slot 0
// (base) -- verified from that write site, and matching DrivesParams["rhru"].
//
// Real data: 8 skills carry 'rhru', all SKILL_EU_BARD_DANCEA_CLERIC_* -- the
// Bard's cleric-dance buff, granting +18/22/26/... % HP healing received with a
// zero MP term. It does not co-occur with 'heal' on the same skill, which is
// the point: the buff is cast on an ally, and a separate heal skill landing on
// that ally later reads param 170 from them.
const HealScaleBuffCode Code = "rhru"
