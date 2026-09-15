package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"math/rand"
	"sort"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/berserk"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/mana"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/quest"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
	"github.com/OpenSRO/srrevamp/server/internal/skill"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// Skill opcodes, our own protocol. All three require a prior OpLogin;
// OpUseSkill additionally requires a prior successful OpEnterWorld (same
// as OpAttack).
const (
	OpLearnSkill       uint16 = 0x0070 // client -> server
	OpLearnSkillResult uint16 = 0x0071 // server -> client
	OpUseSkill         uint16 = 0x0072 // client -> server
	// OpUseSkill's response reuses OpAttackResult -- using a skill is just
	// an attack with a damage bonus, and the client needs the exact same
	// information either way.
	OpSkillList       uint16 = 0x0073 // client -> server
	OpSkillListResult uint16 = 0x0074 // server -> client
	// The skill economy: a character's skill points (earned from mob kills)
	// and its per-mastery trained levels, and raising a mastery a level by
	// spending points. What the skill window's totals and lit/greyed skills
	// are driven by.
	OpSkillState         uint16 = 0x0075 // client -> server
	OpSkillStateResult   uint16 = 0x0076 // server -> client
	OpRaiseMastery       uint16 = 0x0077 // client -> server
	OpRaiseMasteryResult uint16 = 0x0078 // server -> client
)

// MasteryTotalCapPerLevel caps the SUM of a character's mastery levels at this
// multiple of its character level -- 3, so a level-80 character totals 240,
// enough to max three masteries. Recovered from the user's account of the
// retail 80-cap; the pserver's 440 is a mod (some servers raise it to 320 for
// four maxable trees), so it is not used. A single mastery is separately
// capped at the character's own level.
const MasteryTotalCapPerLevel = 3

// masteryUpCost is the skill-point cost to raise a mastery from currentLevel to
// currentLevel+1.
//
// **This is REAL when a level table is loaded.** The pserver's own mastery
// level-up handler (FUN_0059c4e0) walks the levels being raised, accumulates
// the level table's entry+0x10 for each, and refuses the raise when the
// character's skill points (charData+0x80) fall short. A level entry holds the
// int64 EXP requirement at +8, so +0x10 is the field straight after it, which
// is leveldata's column 2 -- 1, 1, 2, 2, 4, 5, 6, 7, 9, 12 ... 53 at level 20
// and 172 at level 32. leveldata.Table.MasteryUpCost serves it.
//
// Falls back to a DISCLOSED own-design currentLevel+1 when no level table is
// loaded (or it predates the column), which is the same shape as the rest of
// the leveling code: real when the operator brings the data, honestly labelled
// when they do not.
func masteryUpCost(currentLevel int) int {
	if cost, ok := levelTable.MasteryUpCost(currentLevel); ok && cost > 0 {
		return cost
	}
	return currentLevel + 1
}

// LearnSkillRequest is the OpLearnSkill payload.
type LearnSkillRequest struct {
	CharacterName string
	SkillID       int64
}

func (r *LearnSkillRequest) Encode() []byte {
	return append(encodeStrings(r.CharacterName), encodeInt64(r.SkillID)...)
}

func DecodeLearnSkillRequest(data []byte) (*LearnSkillRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding LearnSkillRequest: %w", err)
	}
	skillID, _, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding LearnSkillRequest: skill id: %w", err)
	}
	return &LearnSkillRequest{CharacterName: fields[0], SkillID: skillID}, nil
}

// LearnSkillResult is the OpLearnSkillResult payload.
type LearnSkillResult struct {
	OK     bool
	Reason string
}

func (r *LearnSkillResult) Encode() []byte { return encodeOKReason(r.OK, r.Reason) }

func DecodeLearnSkillResult(data []byte) (*LearnSkillResult, error) {
	ok, reason, err := decodeOKReason(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding LearnSkillResult: %w", err)
	}
	return &LearnSkillResult{OK: ok, Reason: reason}, nil
}

// UseSkillRequest is the OpUseSkill payload.
type UseSkillRequest struct {
	CharacterName   string
	SkillID         int64
	TargetMonsterID int64
}

func (r *UseSkillRequest) Encode() []byte {
	out := encodeStrings(r.CharacterName)
	out = append(out, encodeInt64(r.SkillID)...)
	out = append(out, encodeInt64(r.TargetMonsterID)...)
	return out
}

func DecodeUseSkillRequest(data []byte) (*UseSkillRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding UseSkillRequest: %w", err)
	}
	skillID, rest, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding UseSkillRequest: skill id: %w", err)
	}
	targetID, _, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding UseSkillRequest: target id: %w", err)
	}
	return &UseSkillRequest{CharacterName: fields[0], SkillID: skillID, TargetMonsterID: targetID}, nil
}

// SkillRefStore looks up a real skill's learn requirements -- the mastery it
// belongs to, the mastery level it needs, and its SP cost -- what
// LearnSkillHandler gates on. Both refdata stores satisfy it.
type SkillRefStore interface {
	GetSkill(ctx context.Context, id int64) (*refdata.Skill, error)
}

// LearnSkillHandler implements OpLearnSkill against the real skill catalogue: a
// skill is learnable once the character's level in its mastery reaches the
// skill's required mastery level, and it costs the skill's ReqLearnSP (grounded
// _RefSkill data). On success the points are spent and the skill recorded known.
func LearnSkillHandler(chars character.Store, skills skill.Store, skillRef SkillRefStore) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpLearnSkill {
			return nil
		}
		fail := func(reason string) error {
			return sess.Send(&proto.Packet{Opcode: OpLearnSkillResult, Data: (&LearnSkillResult{Reason: reason}).Encode()})
		}
		req, err := DecodeLearnSkillRequest(p.Data)
		if err != nil {
			return fail("malformed request")
		}
		characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
		if errStr != "" {
			return fail(errStr)
		}
		ref, err := skillRef.GetSkill(ctx, req.SkillID)
		if err != nil || ref == nil {
			// Not a real skill -- fall back to the own-design combat catalog
			// (Power Strike etc.), which has no mastery/SP gate. Keeps the
			// learn->use combat flow working alongside real-skill learning.
			if _, ok := skill.Catalog[req.SkillID]; !ok {
				return fail("no such skill")
			}
			if known, _ := skills.Knows(ctx, characterID, req.SkillID); known {
				return fail("already known")
			}
			if err := skills.Learn(ctx, characterID, req.SkillID); err != nil {
				if errors.Is(err, skill.ErrAlreadyKnown) {
					return fail("already known")
				}
				return fail("learn failed")
			}
			return sess.Send(&proto.Packet{Opcode: OpLearnSkillResult, Data: (&LearnSkillResult{OK: true}).Encode()})
		}
		known, err := skills.Knows(ctx, characterID, req.SkillID)
		if err != nil {
			return fail("lookup failed")
		}
		if known {
			return fail("already known")
		}
		// Gated by the mastery level the skill requires.
		if ref.Mastery1 > 0 && ref.MasteryLevel1 > 0 {
			levels, err := skills.MasteryLevels(ctx, characterID)
			if err != nil {
				return fail("lookup failed")
			}
			if levels[ref.Mastery1] < ref.MasteryLevel1 {
				return fail("mastery level too low")
			}
		}
		// Paid for with skill points.
		points, err := skills.SkillPoints(ctx, characterID)
		if err != nil {
			return fail("lookup failed")
		}
		if points < ref.ReqLearnSP {
			return fail("not enough skill points")
		}
		if _, err := skills.AddSkillPoints(ctx, characterID, -ref.ReqLearnSP); err != nil {
			return fail("spending skill points failed")
		}
		if err := skills.Learn(ctx, characterID, req.SkillID); err != nil {
			// Refund on a late failure (e.g. a race that already learned it).
			skills.AddSkillPoints(ctx, characterID, ref.ReqLearnSP)
			if errors.Is(err, skill.ErrAlreadyKnown) {
				return fail("already known")
			}
			return fail("learn failed")
		}
		return sess.Send(&proto.Packet{Opcode: OpLearnSkillResult, Data: (&LearnSkillResult{OK: true}).Encode()})
	}
}

// DisclosedSkillDamagePerLevel is this project's OWN-DESIGN skill-damage rate,
// used ONLY as a fallback now. Real skill damage is recovered -- see
// skillDamageBonus -- but a skill whose row carries no 'att' parameter (and an
// import predating the damage columns) still needs some number, and this stays
// the clearly-labeled stand-in for that case.
const DisclosedSkillDamagePerLevel = 4

// skillDamageBonus is the extra damage a skill adds on top of a plain weapon
// swing. **This is real now**, recovered rather than invented.
//
// A skill's damage lives in its own 'att' parameter in skilldata. Parameters
// are (code, values...) runs in the row's Param block, where the code is a C
// multi-character literal stored as a big-endian integer; the server's own
// parameter parser reads 'att' (0x00617474) as a fixed six-word run, which is
// how the layout is known. The values are (type, percent, min, max, percent),
// and reading a skill across its levels makes the meaning plain: for
// SKILL_CH_SWORD_SMASH_A levels 1-5 the percent holds at 143 while min/max
// climb 15-18, 18-22, 21-26, 25-30, 29-35. A plain swing
// (SKILL_CH_SWORD_BASE_01) is 60 percent with no flat damage -- exactly what a
// basic attack should be.
//
// So a cast deals `percent` of the weapon's damage plus a flat roll in
// [min, max]. Since the caller already applies the plain weapon damage, what is
// returned here is the DIFFERENCE the skill makes: the percentage's surplus (or
// deficit, for a sub-100% skill like a basic swing) plus the flat roll.
//
// Falls back to the disclosed per-level bonus when the skill has no 'att'
// (most skills are buffs, heals or passives) or when the reference data
// predates the damage columns.
func skillDamageBonus(ref *refdata.Skill, weaponDamage int) int {
	if ref.AttackPercent <= 0 {
		return disclosedSkillDamageBonus(ref)
	}
	bonus := weaponDamage*ref.AttackPercent/100 - weaponDamage
	flat := ref.DamageMin
	if ref.DamageMax > ref.DamageMin {
		flat += rand.Intn(ref.DamageMax - ref.DamageMin + 1)
	}
	return bonus + flat
}

// disclosedSkillDamageBonus is the own-design fallback: a bonus scaled by the
// skill's level so higher skills hit harder. Disclosed, not recovered -- see
// DisclosedSkillDamagePerLevel.
func disclosedSkillDamageBonus(ref *refdata.Skill) int {
	lvl := ref.BasicLevel
	if lvl < 1 {
		lvl = 1
	}
	return lvl * DisclosedSkillDamagePerLevel
}

// UseSkillHandler returns a gateway.Handler implementing OpUseSkill:
// checks the character knows the skill and it's off cooldown, then
// delegates to performAttack with the skill's damage bonus. Responds with
// OpAttackResult (see OpUseSkill's doc comment) on all paths, including
// failures, so a client only needs one decoder for both attack types.
func UseSkillHandler(
	chars character.Store,
	eq equipment.Store,
	items combat.ItemLookup,
	skills skill.Store,
	hub *world.Hub,
	monsters *combat.Hub,
	quests quest.Store,
	inv inventory.Store,
	skillRef SkillRefStore,
	zerk *berserk.Tracker,
	mp *mana.Tracker,
) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpUseSkill {
			return nil
		}

		req, err := DecodeUseSkillRequest(p.Data)
		if err != nil {
			return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "malformed request"}).Encode()})
		}

		characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
		if errStr != "" {
			return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: errStr}).Encode()})
		}

		// Resolve the skill's cooldown and damage bonus. A real learned skill
		// (refdata) uses its real ReuseDelay cooldown; its extra damage is a
		// DISCLOSED own-design bonus (disclosedSkillDamageBonus), because the
		// real formula is NOT recoverable: skill damage is server-authoritative
		// (the retail client only receives it in the action packet -- proven by
		// decompiling NetProcessInNavAndSkill.cpp), so it lives only in the
		// packed retail AgentServer, and _RefSkill's Param block is not decoded.
		// So this is a stand-in scaled by the skill's level, clearly labeled --
		// the same accepted pattern as SPFor/ExpFor/Catalog.DamageBonus, never a
		// value dressed as recovered. See the skilldata-columns note.
		// mpCost, unlike the damage bonus, IS real: refdata.Skill.ConsumeMP is
		// the client's own skilldata Consume_MP column. The placeholder
		// catalog skills have no real row and so cost nothing.
		var cooldown time.Duration
		var damageBonus int
		var mpCost int
		if sk, inCatalog := skill.Catalog[req.SkillID]; inCatalog {
			cooldown = time.Duration(sk.CooldownSeconds) * time.Second
			damageBonus = int(sk.DamageBonus)
		} else if ref, err := skillRef.GetSkill(ctx, req.SkillID); err == nil && ref != nil {
			cooldown = time.Duration(ref.ReuseDelayMs) * time.Millisecond
			mpCost = ref.ConsumeMP
			// A skill's damage is a percentage of the wielder's weapon damage
			// plus a flat roll, so the weapon has to be read first -- and the
			// wielder's Strength with it, since it contributes to both ends of
			// that range (see combat.ReinforceDamage).
			weapon := 0
			if eq != nil && items != nil {
				attackerStr := 0
				if c, err := chars.GetByID(ctx, characterID); err == nil && c != nil {
					attackerStr = c.Str
				}
				if w, err := attackerDamage(ctx, characterID, attackerStr, eq, items); err == nil {
					weapon = w
				}
			}
			damageBonus = skillDamageBonus(ref, weapon)
		} else {
			return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "no such skill"}).Encode()})
		}

		knows, err := skills.Knows(ctx, characterID, req.SkillID)
		if err != nil {
			return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "lookup failed"}).Encode()})
		}
		if !knows {
			return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "skill not known"}).Encode()})
		}

		lastUsed, everUsed, err := skills.LastUsed(ctx, characterID, req.SkillID)
		if err != nil {
			return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "lookup failed"}).Encode()})
		}
		now := time.Now()
		if everUsed && cooldown > 0 {
			readyAt := lastUsed.Add(cooldown)
			if now.Before(readyAt) {
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "skill on cooldown"}).Encode()})
			}
		}

		// Pay the skill's real mana cost. Checked after the cooldown gate so a
		// skill that is not ready does not drain anything, and before the use
		// is recorded so a refused cast costs neither mana nor the cooldown.
		if mp != nil && mpCost > 0 {
			owned, err := chars.GetByID(ctx, characterID)
			if err != nil {
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "lookup failed"}).Encode()})
			}
			maxMP := owned.MaxMP()
			if _, ok := mp.Spend(characterID, maxMP, mpCost); !ok {
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "not enough mana"}).Encode()})
			}
		}

		if err := skills.RecordUse(ctx, characterID, req.SkillID, now); err != nil {
			return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "recording use failed"}).Encode()})
		}

		return performAttack(ctx, sess, chars, eq, items, hub, monsters, quests, inv, skills, zerk, mp, characterID, req.TargetMonsterID, damageBonus)
	}
}

// SkillListRequest is the OpSkillList payload.
type SkillListRequest struct {
	CharacterName string
}

func (r *SkillListRequest) Encode() []byte { return encodeStrings(r.CharacterName) }

func DecodeSkillListRequest(data []byte) (*SkillListRequest, error) {
	fields, _, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding SkillListRequest: %w", err)
	}
	return &SkillListRequest{CharacterName: fields[0]}, nil
}

// SkillSnapshot is one catalog skill, as sent over the wire, with the
// requesting character's own real relationship to it (known or not, and how
// many seconds until it's off cooldown -- 0 if it's ready now or was never
// used).
type SkillSnapshot struct {
	ID              int64
	Name            string
	DamageBonus     int32
	CooldownSeconds int32
	Known           bool
	ReadySeconds    int32
}

func (s *SkillSnapshot) Encode() []byte {
	out := append(encodeInt64(s.ID), encodeStrings(s.Name)...)
	buf := make([]byte, 13)
	binary.LittleEndian.PutUint32(buf[0:4], uint32(s.DamageBonus))
	binary.LittleEndian.PutUint32(buf[4:8], uint32(s.CooldownSeconds))
	if s.Known {
		buf[8] = 1
	}
	binary.LittleEndian.PutUint32(buf[9:13], uint32(s.ReadySeconds))
	return append(out, buf...)
}

func decodeSkillSnapshot(data []byte) (*SkillSnapshot, []byte, error) {
	id, rest, err := decodeInt64(data)
	if err != nil {
		return nil, nil, fmt.Errorf("skill id: %w", err)
	}
	names, rest, err := decodeStringsPrefix(rest, 1)
	if err != nil {
		return nil, nil, fmt.Errorf("name: %w", err)
	}
	if len(rest) < 13 {
		return nil, nil, errors.New("truncated fields")
	}
	return &SkillSnapshot{
		ID: id, Name: names[0],
		DamageBonus:     int32(binary.LittleEndian.Uint32(rest[0:4])),
		CooldownSeconds: int32(binary.LittleEndian.Uint32(rest[4:8])),
		Known:           rest[8] != 0,
		ReadySeconds:    int32(binary.LittleEndian.Uint32(rest[9:13])),
	}, rest[13:], nil
}

// SkillListResult is the OpSkillListResult payload.
type SkillListResult struct {
	Error  string
	Skills []SkillSnapshot
}

func (r *SkillListResult) Encode() []byte {
	out := encodeStrings(r.Error)
	if r.Error != "" {
		return out
	}
	countBuf := make([]byte, 2)
	binary.LittleEndian.PutUint16(countBuf, uint16(len(r.Skills)))
	out = append(out, countBuf...)
	for _, s := range r.Skills {
		out = append(out, s.Encode()...)
	}
	return out
}

func DecodeSkillListResult(data []byte) (*SkillListResult, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding SkillListResult: %w", err)
	}
	r := &SkillListResult{Error: fields[0]}
	if r.Error != "" {
		return r, nil
	}

	if len(rest) < 2 {
		return nil, errors.New("session: decoding SkillListResult: truncated skill count")
	}
	count := int(binary.LittleEndian.Uint16(rest))
	rest = rest[2:]
	for i := 0; i < count; i++ {
		var snap *SkillSnapshot
		snap, rest, err = decodeSkillSnapshot(rest)
		if err != nil {
			return nil, fmt.Errorf("session: decoding SkillListResult: skill %d: %w", i, err)
		}
		r.Skills = append(r.Skills, *snap)
	}
	return r, nil
}

// SkillListHandler returns a gateway.Handler implementing OpSkillList:
// responds with every skill in skill.Catalog (sorted by ID for a
// deterministic order -- Go map iteration isn't stable), each annotated
// with whether characterName's account knows it and, if it's on cooldown,
// how many seconds remain.
func SkillListHandler(chars character.Store, store skill.Store) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpSkillList {
			return nil
		}

		req, err := DecodeSkillListRequest(p.Data)
		if err != nil {
			return sess.Send(&proto.Packet{Opcode: OpSkillListResult, Data: (&SkillListResult{Error: "malformed request"}).Encode()})
		}

		characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
		if errStr != "" {
			return sess.Send(&proto.Packet{Opcode: OpSkillListResult, Data: (&SkillListResult{Error: errStr}).Encode()})
		}

		ids := make([]int64, 0, len(skill.Catalog))
		for id := range skill.Catalog {
			ids = append(ids, id)
		}
		sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })

		now := time.Now()
		snapshots := make([]SkillSnapshot, 0, len(ids))
		for _, id := range ids {
			sk := skill.Catalog[id]
			known, err := store.Knows(ctx, characterID, id)
			if err != nil {
				return sess.Send(&proto.Packet{Opcode: OpSkillListResult, Data: (&SkillListResult{Error: "lookup failed"}).Encode()})
			}
			var readySeconds int32
			if known {
				lastUsed, everUsed, err := store.LastUsed(ctx, characterID, id)
				if err != nil {
					return sess.Send(&proto.Packet{Opcode: OpSkillListResult, Data: (&SkillListResult{Error: "lookup failed"}).Encode()})
				}
				if everUsed {
					readyAt := lastUsed.Add(time.Duration(sk.CooldownSeconds) * time.Second)
					if remaining := readyAt.Sub(now); remaining > 0 {
						readySeconds = int32(remaining.Seconds()) + 1
					}
				}
			}
			snapshots = append(snapshots, SkillSnapshot{
				ID: sk.ID, Name: sk.Name, DamageBonus: int32(sk.DamageBonus), CooldownSeconds: int32(sk.CooldownSeconds),
				Known: known, ReadySeconds: readySeconds,
			})
		}
		return sess.Send(&proto.Packet{Opcode: OpSkillListResult, Data: (&SkillListResult{Skills: snapshots}).Encode()})
	}
}

// SkillStateRequest is the OpSkillState payload.
type SkillStateRequest struct {
	CharacterName string
}

func (r *SkillStateRequest) Encode() []byte { return encodeStrings(r.CharacterName) }

func DecodeSkillStateRequest(data []byte) (*SkillStateRequest, error) {
	fields, _, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding SkillStateRequest: %w", err)
	}
	return &SkillStateRequest{CharacterName: fields[0]}, nil
}

// MasterySnapshot is one mastery's trained level, as sent over the wire.
type MasterySnapshot struct {
	MasteryID int64
	Level     int32
}

// SkillStateResult is the OpSkillStateResult payload: the character's level (so
// the client can show the 3x-level mastery cap), its unspent skill points, and
// every mastery it has raised.
type SkillStateResult struct {
	Error       string
	Level       int32
	SkillPoints int32
	Masteries   []MasterySnapshot
	// KnownSkills is the unique per-level skill ids the character has learned,
	// so the window can badge learned skills apart from merely-available ones.
	KnownSkills []int64
}

func (r *SkillStateResult) Encode() []byte {
	out := encodeStrings(r.Error)
	if r.Error != "" {
		return out
	}
	buf := make([]byte, 10)
	binary.LittleEndian.PutUint32(buf[0:4], uint32(r.Level))
	binary.LittleEndian.PutUint32(buf[4:8], uint32(r.SkillPoints))
	binary.LittleEndian.PutUint16(buf[8:10], uint16(len(r.Masteries)))
	out = append(out, buf...)
	for _, m := range r.Masteries {
		out = append(out, encodeInt64(m.MasteryID)...)
		lb := make([]byte, 4)
		binary.LittleEndian.PutUint32(lb, uint32(m.Level))
		out = append(out, lb...)
	}
	kb := make([]byte, 2)
	binary.LittleEndian.PutUint16(kb, uint16(len(r.KnownSkills)))
	out = append(out, kb...)
	for _, id := range r.KnownSkills {
		out = append(out, encodeInt64(id)...)
	}
	return out
}

func DecodeSkillStateResult(data []byte) (*SkillStateResult, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding SkillStateResult: %w", err)
	}
	r := &SkillStateResult{Error: fields[0]}
	if r.Error != "" {
		return r, nil
	}
	if len(rest) < 10 {
		return nil, errors.New("session: decoding SkillStateResult: truncated")
	}
	r.Level = int32(binary.LittleEndian.Uint32(rest[0:4]))
	r.SkillPoints = int32(binary.LittleEndian.Uint32(rest[4:8]))
	count := int(binary.LittleEndian.Uint16(rest[8:10]))
	rest = rest[10:]
	for i := 0; i < count; i++ {
		id, r2, err := decodeInt64(rest)
		if err != nil {
			return nil, fmt.Errorf("session: decoding SkillStateResult: mastery %d id: %w", i, err)
		}
		if len(r2) < 4 {
			return nil, errors.New("session: decoding SkillStateResult: truncated mastery level")
		}
		r.Masteries = append(r.Masteries, MasterySnapshot{MasteryID: id, Level: int32(binary.LittleEndian.Uint32(r2[0:4]))})
		rest = r2[4:]
	}
	if len(rest) >= 2 {
		kcount := int(binary.LittleEndian.Uint16(rest[0:2]))
		rest = rest[2:]
		for i := 0; i < kcount; i++ {
			id, r2, err := decodeInt64(rest)
			if err != nil {
				return nil, fmt.Errorf("session: decoding SkillStateResult: known skill %d: %w", i, err)
			}
			r.KnownSkills = append(r.KnownSkills, id)
			rest = r2
		}
	}
	return r, nil
}

// SkillStateHandler answers OpSkillState with the character's level, unspent
// skill points and per-mastery levels -- what the skill window's totals and
// lit/greyed skills are drawn from.
func SkillStateHandler(chars character.Store, store skill.Store) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpSkillState {
			return nil
		}
		send := func(r *SkillStateResult) error {
			return sess.Send(&proto.Packet{Opcode: OpSkillStateResult, Data: r.Encode()})
		}
		req, err := DecodeSkillStateRequest(p.Data)
		if err != nil {
			return send(&SkillStateResult{Error: "malformed request"})
		}
		characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
		if errStr != "" {
			return send(&SkillStateResult{Error: errStr})
		}
		owned, err := chars.GetByID(ctx, characterID)
		if err != nil {
			return send(&SkillStateResult{Error: "lookup failed"})
		}
		points, err := store.SkillPoints(ctx, characterID)
		if err != nil {
			return send(&SkillStateResult{Error: "lookup failed"})
		}
		levels, err := store.MasteryLevels(ctx, characterID)
		if err != nil {
			return send(&SkillStateResult{Error: "lookup failed"})
		}
		result := &SkillStateResult{Level: int32(owned.Level), SkillPoints: int32(points)}
		for id, lvl := range levels {
			result.Masteries = append(result.Masteries, MasterySnapshot{MasteryID: id, Level: int32(lvl)})
		}
		sort.Slice(result.Masteries, func(i, j int) bool { return result.Masteries[i].MasteryID < result.Masteries[j].MasteryID })
		if learned, err := store.KnownSkills(ctx, characterID); err == nil {
			result.KnownSkills = learned
		}
		return send(result)
	}
}

// RaiseMasteryRequest is the OpRaiseMastery payload.
type RaiseMasteryRequest struct {
	CharacterName string
	MasteryID     int64
}

func (r *RaiseMasteryRequest) Encode() []byte {
	return append(encodeStrings(r.CharacterName), encodeInt64(r.MasteryID)...)
}

func DecodeRaiseMasteryRequest(data []byte) (*RaiseMasteryRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding RaiseMasteryRequest: %w", err)
	}
	id, _, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding RaiseMasteryRequest: mastery id: %w", err)
	}
	return &RaiseMasteryRequest{CharacterName: fields[0], MasteryID: id}, nil
}

// RaiseMasteryResult is the OpRaiseMasteryResult payload.
type RaiseMasteryResult struct {
	Error       string
	MasteryID   int64
	NewLevel    int32
	SkillPoints int32
}

func (r *RaiseMasteryResult) Encode() []byte {
	out := append(encodeStrings(r.Error), encodeInt64(r.MasteryID)...)
	buf := make([]byte, 8)
	binary.LittleEndian.PutUint32(buf[0:4], uint32(r.NewLevel))
	binary.LittleEndian.PutUint32(buf[4:8], uint32(r.SkillPoints))
	return append(out, buf...)
}

func DecodeRaiseMasteryResult(data []byte) (*RaiseMasteryResult, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding RaiseMasteryResult: %w", err)
	}
	id, rest, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding RaiseMasteryResult: mastery id: %w", err)
	}
	if len(rest) < 8 {
		return nil, errors.New("session: decoding RaiseMasteryResult: truncated")
	}
	return &RaiseMasteryResult{
		Error:       fields[0],
		MasteryID:   id,
		NewLevel:    int32(binary.LittleEndian.Uint32(rest[0:4])),
		SkillPoints: int32(binary.LittleEndian.Uint32(rest[4:8])),
	}, nil
}

// RaiseMasteryHandler raises a mastery one level, spending skill points, when
// the character's mastery total is below its cap (MasteryTotalCapPerLevel x
// level) and the mastery is below the character's level (no single mastery can
// exceed it). Answers OpRaiseMasteryResult.
func RaiseMasteryHandler(chars character.Store, store skill.Store) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpRaiseMastery {
			return nil
		}
		fail := func(reason string) error {
			return sess.Send(&proto.Packet{Opcode: OpRaiseMasteryResult, Data: (&RaiseMasteryResult{Error: reason}).Encode()})
		}
		req, err := DecodeRaiseMasteryRequest(p.Data)
		if err != nil {
			return fail("malformed request")
		}
		characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
		if errStr != "" {
			return fail(errStr)
		}
		owned, err := chars.GetByID(ctx, characterID)
		if err != nil {
			return fail("lookup failed")
		}
		levels, err := store.MasteryLevels(ctx, characterID)
		if err != nil {
			return fail("lookup failed")
		}
		total := 0
		for _, lvl := range levels {
			total += lvl
		}
		if total >= MasteryTotalCapPerLevel*owned.Level {
			return fail("mastery total at cap")
		}
		newLevel, err := store.RaiseMastery(ctx, characterID, req.MasteryID, masteryUpCost(levels[req.MasteryID]), owned.Level)
		if err != nil {
			switch {
			case errors.Is(err, skill.ErrMasteryCapped):
				return fail("mastery at level cap")
			case errors.Is(err, skill.ErrInsufficientSkillPoints):
				return fail("not enough skill points")
			default:
				return fail("raise failed")
			}
		}
		points, err := store.SkillPoints(ctx, characterID)
		if err != nil {
			return fail("lookup failed")
		}
		return sess.Send(&proto.Packet{Opcode: OpRaiseMasteryResult, Data: (&RaiseMasteryResult{
			MasteryID: req.MasteryID, NewLevel: int32(newLevel), SkillPoints: int32(points),
		}).Encode()})
	}
}
