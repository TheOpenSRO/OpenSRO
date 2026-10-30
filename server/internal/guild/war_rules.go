package guild

import (
	"encoding/binary"
	"time"
)

// Round 844 (lane V): the whole war, READ in SR_GameServer.exe (s:) and
// SR_ShardManager.exe (m:) -- docs/protocol/guild_war.md has every address.
// The ShardManager's jobs are direct store calls here (one process).

// More refusal codes (category 0x10).
const (
	// ErrWarNotInGuild -- the declarer, or the asker, is in no guild.
	ErrWarNotInGuild = 0x4c0d
	// ErrWarBadTerms -- the victory index above 7 or a period part out of
	// range (s:0x5c6c9x: days > 30, hours > 23, minutes > 50).
	ErrWarBadTerms = 2
	// ErrWarDeclarerGold -- the declarer's gold below the stake (no UIIT
	// name in the client's table; the client shows nothing).
	ErrWarDeclarerGold = 0x4c43
	// ErrWarStakeLimit -- a stake above MaxWarStake (unnamed, INFERRED
	// LIMIT_COMPENSATION).
	ErrWarStakeLimit = 0x4c5e
	// ErrWarDeclarerGone -- the declarer left before the answer.
	ErrWarDeclarerGone = 0x4c0e
	// ErrWarTargetNotMaster -- the answering master no longer leads.
	ErrWarTargetNotMaster = 0x4c24
	// ErrWarRefused -- the target master said no.
	ErrWarRefused = 0x4c16
	// ErrWarTargetGold -- the target master's gold below the stake.
	ErrWarTargetGold = 0x4c0c
	// ErrWarTimedOut -- the target master did not answer in 30 s
	// (s:0x46ce51 -> s:0x5ccd00).
	ErrWarTimedOut = 0x4c10
	// ErrWarNoBooty -- no war reward waiting (UIIT_CTL_GUILDWAR_NOTCOMPENSATION).
	ErrWarNoBooty = 0x4c45
	// ErrWarAllianceHostile -- an alliance proposed to a hostile guild
	// (Guild_ValidateAllianceRequest s:0x5c6550; lane U's flow).
	ErrWarAllianceHostile = 0x4c42
	// ErrWarNoTalk -- the NPC talk the reward requests need (3).
	ErrWarNoTalk = 3
)

// The war's constants.
const (
	// WarRange is how near the declarer must stand to the target guild's
	// master (s:0xb45c40, 300.0, against the 3D distance).
	WarRange = 300.0
	// MaxWarStake is one side's stake cap (s:0x5c6c9e); LodgedGold is two
	// stakes (m:0x435a10).
	MaxWarStake = 500000000
	// WarPeriodUnlimited is the period word with no end (m:0x435a80:
	// 0x7fffffff or more; WarEndTime stored NULL).
	WarPeriodUnlimited = 0x7fffffff
	// WarRequestTimeout is the proclamation's wait (s:0xb45b48).
	WarRequestTimeout = 30 * time.Second
	// WarSurrenderDelay is the end proposal's transaction (m:0x79b020).
	WarSurrenderDelay = 60 * time.Second
	// WarTimeSync is how often the time left goes out (m:0x40c69c).
	WarTimeSync = 60 * time.Second
	// WarTick is the ShardManager's end check (m:0x40c66d).
	WarTick = time.Second
	// RequestKindWar is 0x3080's kind for a proclamation (s:0x5c6f4c).
	RequestKindWar = 10
)

// WarVictoryPoints is the victory-point table (m:0x781ab0); index 0 has no
// target.
var WarVictoryPoints = [8]uint32{0, 5000, 10000, 50000, 100000, 150000, 250000, 300000}

// ParseWarPeriod is m:0x435a80 with the GameServer's checks: days in bits
// 10-14 (<= 30), hours 15-19 (<= 23), minutes 20-25 (<= 50), seconds 26-31.
// unlimited for 0x7fffffff or more; ok false for a part out of range.
func ParseWarPeriod(word uint32) (span time.Duration, unlimited, ok bool) {
	if word >= WarPeriodUnlimited {
		return 0, true, true
	}
	days := (word >> 10) & 0x1f
	hours := (word >> 15) & 0x1f
	minutes := (word >> 20) & 0x3f
	seconds := word >> 26
	if days > 30 || hours > 23 || minutes > 50 {
		return 0, false, false
	}
	return time.Duration(days)*24*time.Hour + time.Duration(hours)*time.Hour +
		time.Duration(minutes)*time.Minute + time.Duration(seconds)*time.Second, false, true
}

// PackWarPeriod is the client's 0x71a810 (minutes in steps of ten there).
func PackWarPeriod(days, hours, minutes int) uint32 {
	return uint32(days&0x1f)<<10 | uint32(hours&0x1f)<<15 | uint32(minutes&0x3f)<<20
}

// WarKillPoints is s:0x5c721x: d = the victim's level less the killer's
// (a COS's own level when one fell): 1 at d <= -6, 251 above 10, else
// 15 d + 100.
func WarKillPoints(victimLevel, killerLevel int) uint32 {
	d := victimLevel - killerLevel
	switch {
	case d <= -6:
		return 1
	case d > 10:
		return 251
	}
	return uint32(15*d + 100)
}

// War is one _GUILDWAR row (DB_Bind s:0x84dd90): +0x18 WarID, +0x1c the type,
// +0x1d the victory index, +0x20 LodgedGold, the end time, +0x34 / +0x38 the
// two guilds (A the declarer, INFERRED), +0x3c / +0x40 their points.
type War struct {
	ID           int64
	Type         byte
	VictoryIndex byte
	LodgedGold   int64
	// EndTime is zero for a war with no end.
	EndTime        time.Time
	GuildA, GuildB int64
	PointsA        int64
	PointsB        int64
	Started        time.Time
}

// Has reports whether guildID is one of the war's two sides.
func (w *War) Has(guildID int64) bool { return w.GuildA == guildID || w.GuildB == guildID }

// Other is the side against guildID.
func (w *War) Other(guildID int64) int64 {
	if w.GuildA == guildID {
		return w.GuildB
	}
	return w.GuildA
}

// Points is guildID's own total.
func (w *War) Points(guildID int64) int64 {
	if w.GuildA == guildID {
		return w.PointsA
	}
	return w.PointsB
}

// SecondsLeft is the E record's u32 (s:0x5cfd30): 0x7fffffff with no end,
// never below 0.
func (w *War) SecondsLeft(now time.Time) uint32 {
	if w.EndTime.IsZero() {
		return WarPeriodUnlimited
	}
	s := int64(w.EndTime.Sub(now) / time.Second)
	if s < 0 {
		return 0
	}
	if s > WarPeriodUnlimited-1 {
		return WarPeriodUnlimited - 1
	}
	return uint32(s)
}

// VictoryTarget is the point total that wins at once (0 none).
func (w *War) VictoryTarget() int64 {
	if int(w.VictoryIndex) < len(WarVictoryPoints) {
		return int64(WarVictoryPoints[w.VictoryIndex])
	}
	return 0
}

// WinnerByPoints is m:0x43c320's test after a kill: a side reaching the
// victory target wins at once.
func (w *War) WinnerByPoints() (int64, bool) {
	t := w.VictoryTarget()
	if t <= 0 {
		return 0, false
	}
	if w.PointsA >= t {
		return w.GuildA, true
	}
	if w.PointsB >= t {
		return w.GuildB, true
	}
	return 0, false
}

// WinnerByTime is the 1 s check (m:0x438430): past the end with the totals
// apart, the higher wins; a tie runs on.
func (w *War) WinnerByTime(now time.Time) (int64, bool) {
	if w.EndTime.IsZero() || now.Before(w.EndTime) || w.PointsA == w.PointsB {
		return 0, false
	}
	if w.PointsA > w.PointsB {
		return w.GuildA, true
	}
	return w.GuildB, true
}

// The war's messages: 0x3109 and 0x38F5's war types (READ, the server's
// writers and the client's FUN_00887330 readers agree).
const (
	OpHostileList uint16 = 0x3109
	OpWarDeclare  uint16 = 0x7110
	OpWarDeclareR uint16 = 0xB110
	OpWarEnd      uint16 = 0x7112
	OpWarEndR     uint16 = 0xB112
	OpWarClaim    uint16 = 0x7113
	OpWarClaimR   uint16 = 0xB113
	OpWarAsk      uint16 = 0x7114
	OpWarAskR     uint16 = 0xB114

	UpdateWarStarted   = 0x19
	UpdateWarEndingFor = 0x1a // to the guild surrendered to
	UpdateWarEndingBy  = 0x1b // to the surrendering guild
	UpdateWarEnded     = 0x1c
	UpdateWarKill      = 0x1d
	UpdateWarTime      = 0x1f
)

func warU32(v int64) uint32 { return uint32(min(max(v, 0), 0xffffffff)) }

// appendWarEntry is E (s:0x5cfd30): u32 id, u32 seconds left, u8 the victory
// index, u32 LodgedGold, u32 A, u32 B, u32 A's points, u32 B's points.
func appendWarEntry(b []byte, w *War, now time.Time) []byte {
	b = binary.LittleEndian.AppendUint32(b, uint32(w.ID))
	b = binary.LittleEndian.AppendUint32(b, w.SecondsLeft(now))
	b = append(b, w.VictoryIndex)
	b = binary.LittleEndian.AppendUint32(b, warU32(w.LodgedGold))
	b = binary.LittleEndian.AppendUint32(b, uint32(w.GuildA))
	b = binary.LittleEndian.AppendUint32(b, uint32(w.GuildB))
	b = binary.LittleEndian.AppendUint32(b, warU32(w.PointsA))
	return binary.LittleEndian.AppendUint32(b, warU32(w.PointsB))
}

// HostileEntry is one 0x3109 entry: the war and the enemy guild's name; a nil
// War (the enemy guild is gone) is written as u32 0.
type HostileEntry struct {
	War       *War
	EnemyName string
}

// EncodeHostileList is 0x3109 (CGuild slot 8, s:0x5c38a0): u8 n, n x (E, str
// the enemy's name), or u32 0 for an enemy no longer there.
func EncodeHostileList(entries []HostileEntry, now time.Time) []byte {
	if len(entries) > 255 {
		entries = entries[:255]
	}
	b := []byte{byte(len(entries))}
	for _, e := range entries {
		if e.War == nil {
			b = binary.LittleEndian.AppendUint32(b, 0)
			continue
		}
		b = appendWarEntry(b, e.War, now)
		b = appendString(b, e.EnemyName)
	}
	return b
}

// EncodeWarStarted is 0x38F5 0x19 (s:0x5cade0): E and the other guild's name.
func EncodeWarStarted(w *War, otherName string, now time.Time) []byte {
	b := appendWarEntry([]byte{UpdateWarStarted}, w, now)
	return appendString(b, otherName)
}

// EncodeWarTime is 0x38F5 0x1f (s:0x5c7d10).
func EncodeWarTime(w *War, now time.Time) []byte {
	b := binary.LittleEndian.AppendUint32([]byte{UpdateWarTime}, uint32(w.ID))
	return binary.LittleEndian.AppendUint32(b, w.SecondsLeft(now))
}

// EncodeWarEnding is 0x38F5 0x1a / 0x1b (s:0x5cac40): u32 the war.
func EncodeWarEnding(kind byte, warID int64) []byte {
	return binary.LittleEndian.AppendUint32([]byte{kind}, uint32(warID))
}

// EncodeWarEnded is 0x38F5 0x1c (s:0x5cb1e0): u32 the war, u32 the winner.
func EncodeWarEnded(warID, winner int64) []byte {
	b := binary.LittleEndian.AppendUint32([]byte{UpdateWarEnded}, uint32(warID))
	return binary.LittleEndian.AppendUint32(b, uint32(winner))
}

// EncodeWarKill is 0x38F5 0x1d (s:0x5cb430): u8 side (1 the killer's guild,
// 2 the victim's), u32 the war, u32 the points, u32 the own member, then the
// opponent: {str name} or, for a job alias, {str "", str alias} (the client
// reads the second string only after an empty first, c:0x888950).
func EncodeWarKill(side byte, warID int64, points uint32, member int64, opponent, alias string) []byte {
	b := binary.LittleEndian.AppendUint32([]byte{UpdateWarKill, side}, uint32(warID))
	b = binary.LittleEndian.AppendUint32(b, points)
	b = binary.LittleEndian.AppendUint32(b, uint32(member))
	if alias != "" {
		b = appendString(b, "")
		return appendString(b, alias)
	}
	return appendString(b, opponent)
}

// EncodeWarProclamation is 0x3080 kind 10 to the target master
// (s:0x46c9e9 -> 0x470d40): u32 the declarer's uid, str its guild, u8 the
// type, u32 the period, u8 the victory index, u32 the stake.
func EncodeWarProclamation(declarer uint32, guildName string, warType byte, period uint32, victory byte, stake uint32) []byte {
	b := binary.LittleEndian.AppendUint32([]byte{RequestKindWar}, declarer)
	b = appendString(b, guildName)
	b = append(b, warType)
	b = binary.LittleEndian.AppendUint32(b, period)
	b = append(b, victory)
	return binary.LittleEndian.AppendUint32(b, stake)
}

// WarDeclaration is 0x7110 (s:0x51c980): str the target guild, u8 the type,
// u32 the period, u8 the victory index, u32 the stake.
type WarDeclaration struct {
	Target       string
	Type         byte
	Period       uint32
	VictoryIndex byte
	Stake        uint32
}

// Encode writes 0x7110 as the client does (c:0x824a30).
func (d WarDeclaration) Encode() []byte {
	b := appendString(nil, d.Target)
	b = append(b, d.Type)
	b = binary.LittleEndian.AppendUint32(b, d.Period)
	b = append(b, d.VictoryIndex)
	return binary.LittleEndian.AppendUint32(b, d.Stake)
}

// DecodeWarDeclaration reads 0x7110.
func DecodeWarDeclaration(data []byte) (WarDeclaration, bool) {
	var d WarDeclaration
	if len(data) < 2 {
		return d, false
	}
	n := int(binary.LittleEndian.Uint16(data))
	if len(data) < 2+n+10 {
		return d, false
	}
	d.Target = string(data[2 : 2+n])
	r := data[2+n:]
	d.Type = r[0]
	d.Period = binary.LittleEndian.Uint32(r[1:])
	d.VictoryIndex = r[5]
	d.Stake = binary.LittleEndian.Uint32(r[6:])
	return d, true
}

// DecodeWarAnswer reads the proclaimed-on master's 0x3080 (c:0x820450: u8 1,
// u8 1 accept / 0 refuse); the server takes the answer byte (s:0x46cb30).
func DecodeWarAnswer(data []byte) (accept, ok bool) {
	if len(data) < 2 {
		return false, len(data) == 1
	}
	return data[0] == 1 && data[1] == 1, true
}
