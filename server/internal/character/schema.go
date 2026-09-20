package character

// The engine's own character row, and how srrevamp's Character maps onto it.
//
// `_CHAR` is one of the 54 runtime tables whose column names SR_GameServer.exe
// declares in its schema pool (docs/protocol/db_columns.md). It introduces 42
// column names, which is the fullest statement available of what the game
// considers a character to be.
//
// This file is not a persistence layer and srrevamp does not use this schema.
// It exists so that every field on Character is either matched to the engine's
// name or recorded as a deliberate divergence -- and so that a divergence
// cannot quietly become an accident.

// EngineCharColumns is `_CHAR`'s column list as the binary declares it, in
// pool order. A test holds this equal to persistence.TableColumns["_CHAR"], so
// a regenerated pool that renamed or dropped one breaks loudly here.
var EngineCharColumns = []string{
	"Deleted", "RefObjID", "CharName16", "NickName16", "Scale",
	"CurLevel", "MaxLevel", "ExpOffset", "SExpOffset",
	"Strength", "Intellect", "RemainGold",
	"RemainSkillPoint", "RemainStatPoint", "RemainHwanCount", "GatheredExpPoint",
	"HP", "MP",
	"LatestRegion", "PosX", "PosY", "PosZ",
	"AppointedTeleport", "AutoInvestExp", "InventorySize",
	"DailyPK", "TotalPK", "PKPenaltyPoint",
	"GuildID", "LastLogout",
	"TelRegion", "TelPosX", "TelPosY", "TelPosZ",
	"DiedRegion", "DiedPosX", "DiedPosY", "DiedPosZ",
	"WorldID", "TelWorldID", "DiedWorldID", "HwanLevel",
}

// FieldMapping is one of srrevamp's Character fields against the engine's.
type FieldMapping struct {
	// Field is the Go field name on Character.
	Field string
	// Column is the `_CHAR` column it corresponds to, or "" when srrevamp
	// keeps the value somewhere the engine does not.
	Column string
	// Note explains a divergence. Empty means the two agree.
	Note string
}

// Mapping covers every field of Character. A test fails if a field is added
// without an entry, which is the point: a new field should have to say whether
// the engine has one.
var Mapping = []FieldMapping{
	{Field: "ID", Column: "",
		Note: "the engine's key is CharID, which the pool attributes to _USER " +
			"because that is where the name first appears; _CHAR uses it as its own key"},
	{Field: "AccountID", Column: "",
		Note: "the engine links a character to _USER rather than storing an account " +
			"id on the row"},
	{Field: "Name", Column: "CharName16"},
	{Field: "Gold", Column: "RemainGold"},
	{Field: "HP", Column: "HP"},
	{Field: "Gender", Column: "",
		Note: "DIVERGENCE. The engine has no gender column: a character's race and " +
			"sex follow from RefObjID, the reference object it is built from. " +
			"srrevamp stores a string because it selects asset paths directly"},
	{Field: "Level", Column: "CurLevel",
		Note: "the engine also keeps MaxLevel, a separate high-water mark srrevamp " +
			"has no equivalent for. _TRAININGCAMPMEMBER carries CharMaxLevel too, " +
			"so it is really tracked and not a duplicate of CurLevel"},
	{Field: "Exp", Column: "ExpOffset",
		Note: "the engine also keeps SExpOffset (skill experience) and " +
			"GatheredExpPoint; srrevamp has neither"},
	{Field: "StatPoints", Column: "RemainStatPoint"},
	{Field: "Str", Column: "Strength",
		Note: "name confirmed: the engine calls it Strength, not STR"},
	{Field: "Int", Column: "Intellect",
		Note: "name confirmed: the engine calls it Intellect, not INT"},
	{Field: "StorageGold", Column: "",
		Note: "DIVERGENCE. The engine has no warehouse gold on the character row; " +
			"storage is the separate _CHEST table"},
	{Field: "HwanCount", Column: "RemainHwanCount",
		Note: "the berserk orbs. Bound by CharData_BindDBColumns to charData +0x86 " +
			"(docs/protocol/db_bind_offsets.tsv), so the engine persists it on the " +
			"character row and srrevamp now does too -- it used to clear on disconnect"},
}

// EngineOnlyColumns are `_CHAR` columns srrevamp models nowhere. Listed rather
// than ignored, because "the engine keeps this and we do not" is the useful
// half of a schema comparison.
var EngineOnlyColumns = map[string]string{
	"Deleted":           "the engine soft-deletes characters; srrevamp deletes the row",
	"RefObjID":          "the reference object a character is built from -- what srrevamp's Gender stands in for",
	"NickName16":        "a second name, separate from CharName16",
	"Scale":             "body scale",
	"MaxLevel":          "a high-water mark beside CurLevel",
	"SExpOffset":        "skill experience, beside ExpOffset",
	"RemainSkillPoint":  "srrevamp keeps SP in internal/skill's own store, not on the character",
	"GatheredExpPoint":  "a lifetime total beside the per-level ExpOffset",
	"MP":                "SEE internal/mana: the engine PERSISTS current MP and srrevamp does not",
	"LatestRegion":      "position, which srrevamp keeps in the live world rather than on the row",
	"PosX":              "position",
	"PosY":              "position",
	"PosZ":              "position",
	"AppointedTeleport": "a bound return point",
	"AutoInvestExp":     "automatic stat investment",
	"InventorySize":     "a per-character inventory width; srrevamp's is fixed",
	"DailyPK":           "the PK economy, which srrevamp has no part of",
	"TotalPK":           "the PK economy",
	"PKPenaltyPoint":    "the PK economy",
	"GuildID":           "srrevamp's guild membership lives in internal/guild's store",
	"LastLogout":        "session bookkeeping",
	"TelRegion":         "the return-scroll position, four columns",
	"TelPosX":           "the return-scroll position",
	"TelPosY":           "the return-scroll position",
	"TelPosZ":           "the return-scroll position",
	"DiedRegion":        "where the character last died, four columns",
	"DiedPosX":          "where the character last died",
	"DiedPosY":          "where the character last died",
	"DiedPosZ":          "where the character last died",
	"WorldID":           "which game world the character is in",
	"TelWorldID":        "the return point's world",
	"DiedWorldID":       "the death point's world",
	"HwanLevel":         "the berserk level, persisted",
}
