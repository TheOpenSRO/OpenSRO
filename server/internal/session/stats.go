package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"math"

	"github.com/TheOpenSRO/OpenSRO/server/internal/buff"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/durability"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mana"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/skill"
)

// The character-stats exchange: the client asks what its own character is
// worth, and gets back the numbers the server itself fights with.
const (
	OpCharacterStats       uint16 = 0x00EE // client -> server
	OpCharacterStatsResult uint16 = 0x00EF // server -> client
	// OpSpendStatPoints puts unspent stat points into Strength and/or
	// Intellect; the reply is an OpCharacterStatsResult with the new numbers.
	OpSpendStatPoints uint16 = 0x00F0 // client -> server
)

// CharacterStatsResult is what the character panel and the inventory's
// gold readout are filled from.
//
// **Only what the server really has.** The panel (`resinfo\ifplayerinfo.txt`)
// has rows this server can state and rows it cannot. Stated: level, exp and
// exp-to-next (the real leveldata curve), Str/Int and the unspent stat points,
// HP/MaxHP and MP/MaxMP (the game's own formulas), the physical and magical
// attack RANGES (combat.WeaponRange, the engine's own parameter graph), and
// the two defence sums combat already fights with. Physical/magical BALANCE
// needs no field: the client computes it from Str/Int and the level (round
// 629 read the formula in both CIFPlayerInfo and CIFPlayerMiniInfo). HIT RATE
// and PARRY are the fifth and sixth tails (round 629's review): engine params
// 11 and 9, which combat already uses to place every blow (rounds 378/379).
// Not stated: the three job grades and honour (no job or honour system here).
//
// PhysAttack/PhysDefense are the original pair and keep their place so an
// older client still parses; the rest is an additive tail.
type CharacterStatsResult struct {
	Error string

	Gold  int64
	HP    int32
	MaxHP int32

	// PhysAttack is the equipped weapon's PhysAttackMax, or the unarmed
	// damage when nothing is equipped. PhysDefense sums each worn armour
	// piece's physical defence through its instance's variance.
	PhysAttack  int32
	PhysDefense int32

	// Level, Exp and ExpToNext drive the underbar's EXP gauge and the
	// player-info level; SkillPoints is the unspent SP shown beside it.
	// ExpToNext is 0 when no level curve is loaded (then the gauge is empty).
	Level       int32
	Exp         int64
	ExpToNext   int64
	SkillPoints int32

	// MP and MaxMP drive the mana bar. MaxMP is the game's own formula
	// (character.MaxMPFor, from the character's Int), so this is a real
	// number rather than the blank bar the HUD used to draw. MP is what is
	// left after paying skills' real Consume_MP costs.
	MP    int32
	MaxMP int32

	// The character rows (2026-09-19). Str/Int are the stored stats, StatPoints
	// the unspent pool the "+" buttons draw from (GObjPC_SpendStatPoints'
	// rule: a spend of s+i is refused unless s+i <= pool, then Str += s,
	// Int += i -- see character.StatGrowthPerLevel's reading).
	Str        int32
	Int        int32
	StatPoints int32

	// The attack ROWS are ranges, as the client's own "%d ~ %d" draws them:
	// PhysAttackMin..PhysAttack and MagAttackMin..MagAttackMax, both from
	// combat.WeaponRange -- the weapon's columns plus the Str (physical) or
	// Int (magical) reinforce term the engine's parameter graph assigns.
	// Unarmed: the physical pair is the unarmed damage, the magical pair 0.
	// MagDefense is the worn armour's magic defence exactly as PhysDefense
	// is its physical: each piece's range through its instance's variance
	// (the engine's own interpolation, see defenderArmor).
	PhysAttackMin int32
	MagAttackMin  int32
	MagAttackMax  int32
	MagDefense    int32

	// HwanCount is the berserk orbs held, the persisted _CHAR.RemainHwanCount
	// (0..berserk.Orbs) -- the fourth tail (round 629). The client draws the
	// player block's orbs from it (CIFPlayerMiniInfo reads the same count,
	// player+0x886, every refresh), so they are right from the moment the
	// world loads rather than only after the first blow's AttackResult.
	HwanCount int32

	// HitRate and ParryRate are the rows retail's server sends in 0x303D (the
	// client's FUN_00880f80 stores them as the u16s at +0x14 and +0x16 of the
	// stats block both windows draw), built by CGObjPC::vslot_334 (0x4ebe30)
	// from params 11 and 9. They are the numbers combat already places blows
	// with: combat.CharacterRate(level, the worn weapon instance's attack
	// rate) and CharacterRate(level, defenderParryRate), rounded
	// (characterRates, which also discloses what retail adds and this does
	// not: buffs, masteries and the per-plus increments).
	HitRate   int32
	ParryRate int32
}

func (r *CharacterStatsResult) Encode() []byte {
	out := encodeStrings(r.Error)
	buf := make([]byte, 96)
	binary.LittleEndian.PutUint64(buf[0:8], uint64(r.Gold))
	binary.LittleEndian.PutUint32(buf[8:12], uint32(r.HP))
	binary.LittleEndian.PutUint32(buf[12:16], uint32(r.MaxHP))
	binary.LittleEndian.PutUint32(buf[16:20], uint32(r.PhysAttack))
	binary.LittleEndian.PutUint32(buf[20:24], uint32(r.PhysDefense))
	binary.LittleEndian.PutUint32(buf[24:28], uint32(r.Level))
	binary.LittleEndian.PutUint64(buf[28:36], uint64(r.Exp))
	binary.LittleEndian.PutUint64(buf[36:44], uint64(r.ExpToNext))
	binary.LittleEndian.PutUint32(buf[44:48], uint32(r.SkillPoints))
	binary.LittleEndian.PutUint32(buf[48:52], uint32(r.MP))
	binary.LittleEndian.PutUint32(buf[52:56], uint32(r.MaxMP))
	binary.LittleEndian.PutUint32(buf[56:60], uint32(r.Str))
	binary.LittleEndian.PutUint32(buf[60:64], uint32(r.Int))
	binary.LittleEndian.PutUint32(buf[64:68], uint32(r.StatPoints))
	binary.LittleEndian.PutUint32(buf[68:72], uint32(r.PhysAttackMin))
	binary.LittleEndian.PutUint32(buf[72:76], uint32(r.MagAttackMin))
	binary.LittleEndian.PutUint32(buf[76:80], uint32(r.MagAttackMax))
	binary.LittleEndian.PutUint32(buf[80:84], uint32(r.MagDefense))
	binary.LittleEndian.PutUint32(buf[84:88], uint32(r.HwanCount))
	binary.LittleEndian.PutUint32(buf[88:92], uint32(r.HitRate))
	binary.LittleEndian.PutUint32(buf[92:96], uint32(r.ParryRate))
	return append(out, buf...)
}

func DecodeCharacterStatsResult(data []byte) (*CharacterStatsResult, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding CharacterStatsResult: %w", err)
	}
	if len(rest) < 24 {
		return nil, errors.New("session: decoding CharacterStatsResult: truncated")
	}
	r := &CharacterStatsResult{
		Error:       fields[0],
		Gold:        int64(binary.LittleEndian.Uint64(rest[0:8])),
		HP:          int32(binary.LittleEndian.Uint32(rest[8:12])),
		MaxHP:       int32(binary.LittleEndian.Uint32(rest[12:16])),
		PhysAttack:  int32(binary.LittleEndian.Uint32(rest[16:20])),
		PhysDefense: int32(binary.LittleEndian.Uint32(rest[20:24])),
	}
	// The level/exp/SP tail is appended, so an older 24-byte result still
	// decodes (with these left 0).
	if len(rest) >= 48 {
		r.Level = int32(binary.LittleEndian.Uint32(rest[24:28]))
		r.Exp = int64(binary.LittleEndian.Uint64(rest[28:36]))
		r.ExpToNext = int64(binary.LittleEndian.Uint64(rest[36:44]))
		r.SkillPoints = int32(binary.LittleEndian.Uint32(rest[44:48]))
	}
	// The mana pair is appended in turn, so a 48-byte result still decodes.
	if len(rest) >= 56 {
		r.MP = int32(binary.LittleEndian.Uint32(rest[48:52]))
		r.MaxMP = int32(binary.LittleEndian.Uint32(rest[52:56]))
	}
	// The character rows (stats, pool, ranges, magical defence) are the
	// third tail, so a 56-byte result still decodes with them left 0.
	if len(rest) >= 84 {
		r.Str = int32(binary.LittleEndian.Uint32(rest[56:60]))
		r.Int = int32(binary.LittleEndian.Uint32(rest[60:64]))
		r.StatPoints = int32(binary.LittleEndian.Uint32(rest[64:68]))
		r.PhysAttackMin = int32(binary.LittleEndian.Uint32(rest[68:72]))
		r.MagAttackMin = int32(binary.LittleEndian.Uint32(rest[72:76]))
		r.MagAttackMax = int32(binary.LittleEndian.Uint32(rest[76:80]))
		r.MagDefense = int32(binary.LittleEndian.Uint32(rest[80:84]))
	}
	// The orb count is the fourth tail; an 84-byte result decodes with it 0.
	if len(rest) >= 88 {
		r.HwanCount = int32(binary.LittleEndian.Uint32(rest[84:88]))
	}
	// Hit rate and parry are the fifth and sixth tails; an 88-byte result
	// decodes with them 0.
	if len(rest) >= 96 {
		r.HitRate = int32(binary.LittleEndian.Uint32(rest[88:92]))
		r.ParryRate = int32(binary.LittleEndian.Uint32(rest[92:96]))
	}
	return r, nil
}

// SpendStatPointsRequest is OpSpendStatPoints' payload: whose points, and
// how many go to Strength and to Intellect.
type SpendStatPointsRequest struct {
	Name string
	Str  uint8
	Int  uint8
}

func (r *SpendStatPointsRequest) Encode() []byte {
	return append(encodeStrings(r.Name), r.Str, r.Int)
}

func DecodeSpendStatPointsRequest(data []byte) (*SpendStatPointsRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding SpendStatPointsRequest: %w", err)
	}
	if len(rest) < 2 {
		return nil, errors.New("session: decoding SpendStatPointsRequest: truncated")
	}
	return &SpendStatPointsRequest{Name: fields[0], Str: rest[0], Int: rest[1]}, nil
}

// weaponRanges is what the character panel's two attack rows show: the
// physical and magical damage ranges of the equipped weapon for this
// character, through the same combat.WeaponRange a real blow uses. With no
// weapon (or one nobody has stats for) the physical pair is the unarmed
// damage and the magical pair is zero -- exactly what a swing would do.
func weaponRanges(ctx context.Context, characterID int64, str, intel int, eq equipment.Store, items combat.ItemLookup) (pMin, pMax, mMin, mMax int, err error) {
	equipped, err := eq.Get(ctx, characterID)
	if err != nil {
		return 0, 0, 0, 0, fmt.Errorf("reading equipment: %w", err)
	}
	for _, e := range equipped {
		if e.Slot != equipment.SlotWeapon {
			continue
		}
		// A broken weapon swings bare-fisted (attackerDamageOf); the panel
		// shows that too (round 769's review F7).
		if durability.IsBroken(e.Durability) {
			break
		}
		item, err := items.GetItem(ctx, e.ItemID)
		if errors.Is(err, refdata.ErrItemNotFound) {
			break
		}
		if err != nil {
			return 0, 0, 0, 0, fmt.Errorf("looking up weapon stats: %w", err)
		}
		pMin, pMax = combat.WeaponRange(item, weaponInstance(e), str, intel, combat.AttackPhysical)
		mMin, mMax = combat.WeaponRange(item, weaponInstance(e), str, intel, combat.AttackMagical)
		return pMin, pMax, mMin, mMax, nil
	}
	return unarmedDamage, unarmedDamage, 0, 0, nil
}

// defenderMagicArmor is defenderArmor's twin for the magical column: each
// worn piece's MD_L..MD_U through the instance's variance, group 4 for armour
// (durability.ArmourMagDefenseGroup; Char_BuildAggregateStats' block at
// 0x495fa0 -> item+0x1a8, param 6) and group 5 for the shield (0x4968a4).
// The same walk, so the two defence rows are built the same way.
func defenderMagicArmor(ctx context.Context, characterID int64, eq equipment.Store, items combat.ItemLookup) (int, error) {
	v, err := defenderDefence(ctx, characterID, eq, items, func(it *refdata.Item) (float64, float64, float64) {
		return it.MagDefenseMin, it.MagDefenseMax, it.PlusIncMagDef
	}, durability.ArmourMagDefenseGroup, durability.ShieldMagDefenseGroup)
	// Round 785: the buffs' param-6 entries (buffstats.go).
	return buffStatInt(characterID, buff.ParamMagDefFlat, v), err
}

// characterRates is the character's attack rate and parry rate as combat uses
// them (performAttack's centre roll and monsterBlow's): the innate 10 plus the
// level plus the worn weapon's own attack rate (combat.WeaponAttackRate: the
// instance's variance group 3, param 11's item term), and the same over the
// body armour's parry (defenderParryRate: each piece's variance group 5,
// param 9's), each rounded for the panel's "%d". An unarmed character's
// weapon term is 0, which CharacterRate takes as it is; so is a BROKEN
// weapon's, as combat swings it bare-fisted (attackerDamageOf) and the
// publisher zeroes a broken item's params.
//
// DISCLOSED, what retail adds and this does not: params 11 and 9 also take
// buffs and masteries, which OpenSRO's params carry no term for here, so a
// buffed character reads lower than on a retail panel. Each item's per-plus
// increment (columns 115 and 70) and its 'hr' / 'er' option do count since
// round 769 (combat.WeaponAttackRate, armourParry).
func characterRates(ctx context.Context, level int, characterID int64, eq equipment.Store, items combat.ItemLookup) (hit, parry int, err error) {
	equipped, err := eq.Get(ctx, characterID)
	if err != nil {
		return 0, 0, fmt.Errorf("reading equipment: %w", err)
	}
	weaponRate := 0.0
	for _, e := range equipped {
		if e.Slot != equipment.SlotWeapon {
			continue
		}
		if durability.IsBroken(e.Durability) {
			break
		}
		if it, err := items.GetItem(ctx, e.ItemID); err == nil && it != nil {
			weaponRate = combat.WeaponAttackRate(it, weaponInstance(e))
		}
		break
	}
	era, err := defenderParryRate(ctx, characterID, eq, items)
	if err != nil {
		return 0, 0, err
	}
	return int(math.Round(combat.CharacterRate(level, weaponRate))), int(math.Round(combat.CharacterRate(level, era))), nil
}

// buildCharacterStats fills a CharacterStatsResult for owned from every
// source the server has; it is what both the stats request and a stat-point
// spend answer with.
func buildCharacterStats(ctx context.Context, owned *character.Character, characterID int64, eq equipment.Store, items combat.ItemLookup, skills skill.Store, mp *mana.Tracker) (*CharacterStatsResult, error) {
	// Max mana is the game's own curve; current mana is what the caster
	// has left after paying skills' real Consume_MP costs.
	maxMP := owned.MaxMP()
	curMP := maxMP
	if mp != nil {
		curMP = mp.Current(characterID, maxMP)
	}
	result := &CharacterStatsResult{
		Gold: owned.Gold,
		// No more than the max (round 769): taking off, swapping or breaking
		// a piece with an 'hp' option lowers it, and the handlers clamp the
		// stored HP then (clampHP); this guards any path that does not.
		HP:    int32(min(owned.HP, owned.MaxHP())),
		MaxHP: int32(owned.MaxHP()),
		Level: int32(owned.Level),
		Exp:   owned.Exp,
		MP:    int32(curMP),
		MaxMP: int32(maxMP),
		// Round 769: param 1 / 2, the TOTAL -- the character's own and its
		// worn items' options (the 0x303D builder sends round(GetParam(1));
		// the panel prints that one number).
		Str:        int32(owned.TotalStr()),
		Int:        int32(owned.TotalInt()),
		StatPoints: int32(owned.StatPoints),
		HwanCount:  int32(owned.HwanCount),
	}
	if levelTable.Loaded() {
		if toNext, ok := levelTable.ExpToNext(owned.Level); ok {
			result.ExpToNext = toNext
		}
	}
	if skills != nil {
		if sp, err := skills.SkillPoints(ctx, characterID); err == nil {
			result.SkillPoints = int32(sp)
		}
	}
	if eq != nil && items != nil {
		pMin, pMax, mMin, mMax, err := weaponRanges(ctx, characterID, owned.TotalStr(), owned.TotalInt(), eq, items)
		if err != nil {
			return nil, err
		}
		armor, err := defenderArmor(ctx, characterID, eq, items)
		if err != nil {
			return nil, err
		}
		magic, err := defenderMagicArmor(ctx, characterID, eq, items)
		if err != nil {
			return nil, err
		}
		// PhysAttack used to be one ROLL of the range on every request, so
		// the panel showed a different attack each time it opened. It is the
		// range's top now, with the bottom beside it.
		result.PhysAttackMin = int32(pMin)
		result.PhysAttack = int32(pMax)
		result.MagAttackMin = int32(mMin)
		result.MagAttackMax = int32(mMax)
		result.PhysDefense = int32(armor)
		result.MagDefense = int32(magic)
		hit, parry, err := characterRates(ctx, owned.Level, characterID, eq, items)
		if err != nil {
			return nil, err
		}
		result.HitRate = int32(hit)
		result.ParryRate = int32(parry)
	}
	return result, nil
}

// CharacterStatsHandler answers OpCharacterStats. skills supplies the unspent
// skill-point count (may be nil); the session's level table supplies the
// exp-to-next for the EXP gauge.
// mp may be nil, in which case mana is reported full.
func CharacterStatsHandler(chars character.Store, eq equipment.Store, items combat.ItemLookup, skills skill.Store, mp *mana.Tracker) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpCharacterStats {
			return nil
		}
		req, err := DecodeCharacterNameRequest(p.Data)
		if err != nil {
			return sess.Send(&proto.Packet{
				Opcode: OpCharacterStatsResult,
				Data:   (&CharacterStatsResult{Error: "malformed request"}).Encode(),
			})
		}
		characterID, reason := resolveCharacterID(ctx, sess, chars, req.Name)
		if characterID < 0 {
			return sess.Send(&proto.Packet{
				Opcode: OpCharacterStatsResult,
				Data:   (&CharacterStatsResult{Error: reason}).Encode(),
			})
		}
		owned, err := chars.GetByID(ctx, characterID)
		if err != nil {
			return sess.Send(&proto.Packet{
				Opcode: OpCharacterStatsResult,
				Data:   (&CharacterStatsResult{Error: "lookup failed"}).Encode(),
			})
		}
		result, err := buildCharacterStats(ctx, owned, characterID, eq, items, skills, mp)
		if err != nil {
			return sess.Send(&proto.Packet{
				Opcode: OpCharacterStatsResult,
				Data:   (&CharacterStatsResult{Error: "reading equipment"}).Encode(),
			})
		}
		return sess.Send(&proto.Packet{Opcode: OpCharacterStatsResult, Data: result.Encode()})
	}
}

// SpendStatPointsHandler answers OpSpendStatPoints with the engine's own
// rule, GObjPC_SpendStatPoints (0x00511470): the spend s+i is refused unless
// s+i <= the unspent pool, and it only ever ADDS -- Str += s, Int += i, pool
// -= s+i. The reply is the refreshed CharacterStatsResult so the panel's
// numbers, and the HP/MP the stats derive, move together.
func SpendStatPointsHandler(chars character.Store, eq equipment.Store, items combat.ItemLookup, skills skill.Store, mp *mana.Tracker) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpSpendStatPoints {
			return nil
		}
		refuse := func(why string) error {
			return sess.Send(&proto.Packet{
				Opcode: OpCharacterStatsResult,
				Data:   (&CharacterStatsResult{Error: why}).Encode(),
			})
		}
		req, err := DecodeSpendStatPointsRequest(p.Data)
		if err != nil {
			return refuse("malformed request")
		}
		characterID, reason := resolveCharacterID(ctx, sess, chars, req.Name)
		if characterID < 0 {
			return refuse(reason)
		}
		// The row's read and write under the leveling lock (round 712: a
		// party member's kill can pay this character from another goroutine).
		unlock := character.LockLeveling(characterID)
		owned, err := chars.GetByID(ctx, characterID)
		if err != nil {
			unlock()
			return refuse("lookup failed")
		}
		want := int(req.Str) + int(req.Int)
		if want <= 0 {
			unlock()
			return refuse("nothing to spend")
		}
		if want > owned.StatPoints {
			unlock()
			return refuse("not enough stat points")
		}
		err = chars.SetLeveling(ctx, characterID, owned.Level, owned.Exp,
			owned.StatPoints-want, owned.Str+int(req.Str), owned.Int+int(req.Int))
		unlock()
		if err != nil {
			return refuse("saving stats failed")
		}
		owned, err = chars.GetByID(ctx, characterID)
		if err != nil {
			return refuse("lookup failed")
		}
		result, err := buildCharacterStats(ctx, owned, characterID, eq, items, skills, mp)
		if err != nil {
			return refuse("reading equipment")
		}
		return sess.Send(&proto.Packet{Opcode: OpCharacterStatsResult, Data: result.Encode()})
	}
}
