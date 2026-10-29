package session

// Round 840, lane B: the GM's chat and trade bans, the quest block, and the
// hooks for the stall refusals OpenSRO has no state for. READ from
// SR_GameServer.exe (s:) and sro_client.exe (c:) unless marked;
// docs/protocol/stall.md and docs/protocol/opcodes/login.md ("Punishments")
// have the reading.
//
// The restriction slots. Retail's game server keeps, per player, a block at
// pc+0x188 with two slots {u8 active, SYSTEMTIME end} at +0x44 + (slot - 3) *
// 0x11: slot 3 the trade ban, slot 4 the chat ban (s:0x40b870). They are set
// and cleared only by a server-to-server message from the account side
// (s:0x416bd0: {u32 user, u8 1 set | 2 clear, u8 slot, [SYSTEMTIME end]};
// setter s:0x40b7f0, clearer s:0x40b840) -- the operator console's
// punishments ("block p2p trade" 3, "block chat" 4), which OpenSRO keeps as
// account.PunishTrade / PunishChat in account_punishments (round 788).
// FUN_004f0a00(kind) (s:0x4f0a00) is the one test: kind 0 reads slot 4, kind
// 1 slot 3; a held slot answers 0x3405 {u8 kind, u32 packed end}
// (PackSystemTime s:0x4f8860) and returns 1, and the caller drops the
// request. Its twelve callers:
//
//	kind 1 (trade): the exchange request (s:0x515530), the stall open
//	  (s:0x515f21) and enter (s:0x51627b), the consignment's session
//	  (OpenMarket_BeginSession s:0x51b585), the item drop (s:0x5264f0, the
//	  StorageOperation drop types);
//	kind 0 (chat): every chat line, before its type is read (s:0x4b17ce), the
//	  global chatting item (CGItemExpendable::vslot_307 case 5, s:0x49c0f2:
//	  answer 2, nothing used), the stall's name at the open (s:0x471db6:
//	  CharName + one of eleven suffixes, chatBannedStallName), the guild notice
//	  (s:0x516edf), the messenger's letters (s:0x51815f, 0x518379) and the
//	  training camp's notice (s:0x51993f).
//
// OpenSRO checks the ones it has: chat, the global chatting item, the
// exchange request, the stall open, enter and name. It has no consignment,
// no player item drop, no letters and no guild or academy notice.
//
// The client (c:0x86e5b0) formats UIIT_MSG_GM_PUNISHMENT_CHAT_BLOCK or
// UIIT_MSG_GM_PUNISHMENT_TRADE_BLOCK with the end's year, month, day,
// forenoon / afternoon, hour (12-hour) and minute, and shows it in the
// warning banner (0x77b580) and as a system line of type 5 (0x7781b0).
//
// OURS, disclosed:
//   - The slots are read from the account's active punishments (both stores)
//     and cached a while (restrictionTTL); a GM's /chatban, /tradeban and
//     their un- forms drop the cache at once (ForgetRestrictions). Retail's
//     account side pushes each change; a row an operator writes straight
//     into the database is seen within restrictionTTL here.
//   - A slot whose end has passed is not held (retail's flag stays set until
//     the account side clears it, INFERRED to be at the end).
//   - An infinite punishment's end is sent as its begin plus 100 years, as
//     the operator console's "Set Infinite Duration" stores it (login.md).

import (
	"context"
	"encoding/binary"
	"log/slog"
	"math/rand"
	"strings"
	"sync"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// OpRestriction is 0x3405 {u8 kind, u32 packed end} (s:0x4f0a6c; client
// c:0x86e5b0).
const OpRestriction uint16 = 0x3405

// FUN_004f0a00's kinds, the wire's first byte.
const (
	RestrictChat  byte = 0 // slot 4, the chat ban
	RestrictTrade byte = 1 // slot 3, the trade ban
)

// restrictionTTL is how long an account's slots are kept before the store is
// read again (OURS).
const restrictionTTL = 30 * time.Second

// infiniteRestrictionYears is the end an infinite punishment is sent with:
// its begin plus 100 years (login.md, the operator console's infinite date).
const infiniteRestrictionYears = 100

type restrictionSlot struct {
	held bool
	end  time.Time
}

type restrictionEntry struct {
	read  time.Time
	slots [2]restrictionSlot // by kind
}

type restrictionCache struct {
	mu        sync.Mutex
	store     account.PunishmentStore
	byAccount map[int64]restrictionEntry
	now       func() time.Time
}

var restrictions = &restrictionCache{byAccount: map[int64]restrictionEntry{}, now: time.Now}

// SetRestrictionStore is where the chat and trade bans are read from (the
// account store's punishments); nil holds no account restricted.
func SetRestrictionStore(s account.PunishmentStore) {
	restrictions.mu.Lock()
	defer restrictions.mu.Unlock()
	restrictions.store = s
	restrictions.byAccount = map[int64]restrictionEntry{}
}

// ForgetRestrictions drops accountID's cached slots: the next check reads the
// store (a GM's ban or unban).
func ForgetRestrictions(accountID int64) {
	restrictions.mu.Lock()
	defer restrictions.mu.Unlock()
	delete(restrictions.byAccount, accountID)
}

// slotOf is accountID's slot for kind: held, and its end.
func (c *restrictionCache) slotOf(ctx context.Context, accountID int64, kind byte) restrictionSlot {
	if kind > RestrictTrade {
		return restrictionSlot{}
	}
	c.mu.Lock()
	store, now := c.store, c.now()
	e, ok := c.byAccount[accountID]
	c.mu.Unlock()
	if store == nil {
		return restrictionSlot{}
	}
	if !ok || now.Sub(e.read) >= restrictionTTL {
		e = restrictionEntry{read: now}
		active, err := store.ActivePunishments(ctx, accountID, now)
		if err != nil {
			slog.Warn("restriction: reading the account's punishments", "account", accountID, "err", err)
			return restrictionSlot{}
		}
		// ActivePunishments puts the one ending last first: that is the end.
		for _, p := range active {
			k := -1
			switch p.Type {
			case account.PunishChat:
				k = int(RestrictChat)
			case account.PunishTrade:
				k = int(RestrictTrade)
			}
			if k < 0 || e.slots[k].held {
				continue
			}
			end := p.EndAt
			if p.Infinite() {
				end = p.BeginAt.AddDate(infiniteRestrictionYears, 0, 0)
			}
			e.slots[k] = restrictionSlot{held: true, end: end}
		}
		c.mu.Lock()
		c.byAccount[accountID] = e
		c.mu.Unlock()
	}
	s := e.slots[kind]
	if s.held && !now.Before(s.end) {
		return restrictionSlot{}
	}
	return s
}

// PackSystemTime is s:0x4f8860 on t's local time: (year - 16) & 0x3f, month,
// day, hour, minute, second in 6/4/5/5/6/6 bits (PACKET_FORMAT.md).
func PackSystemTime(t time.Time) uint32 {
	t = t.Local()
	return uint32((t.Year()-16)&0x3f) | uint32(t.Month()&0xf)<<6 | uint32(t.Day()&0x1f)<<10 |
		uint32(t.Hour()&0x1f)<<15 | uint32(t.Minute()&0x3f)<<20 | uint32(t.Second()&0x3f)<<26
}

// EncodeRestriction is 0x3405.
func EncodeRestriction(kind byte, end time.Time) []byte {
	return binary.LittleEndian.AppendUint32([]byte{kind}, PackSystemTime(end))
}

// restricted is FUN_004f0a00(kind) for the player on sess: true, with 0x3405
// sent, when the account's slot is held; the caller then drops the request.
func restricted(ctx context.Context, sess *gateway.Session, kind byte) bool {
	if sess == nil {
		return false
	}
	id, ok := AuthenticatedAccountID(sess)
	if !ok {
		return false
	}
	s := restrictions.slotOf(ctx, id, kind)
	if !s.held {
		return false
	}
	sendToPeer(sess, &proto.Packet{Opcode: OpRestriction, Data: EncodeRestriction(kind, s.end)})
	slog.Info("restriction: refused", "account", id, "kind", kind, "until", s.end)
	return true
}

// The chat-banned owner's stall name (s:0x471d90): the character's name and
// one of these, picked by rand() over the table's size (s:0x471dfc). READ
// the eleven strings at s:0xae6840..0xae68a4 in their push order
// (s:0x473d8b..0x4740cc).
var chatBannedStallSuffixes = [...]string{
	" ^_^;", "'s Shop", " :-p", " -_-v", " ~m^o^m~", " -,.-a", " :-D", "...",
	" Best Price, Best Goods !!!", " @_@", " :->",
}

// chatBannedStallName is the name a chat-banned owner's stall opens with.
func chatBannedStallName(charName string) string {
	return charName + chatBannedStallSuffixes[rand.Intn(len(chatBannedStallSuffixes))]
}

// --- the quest block ---------------------------------------------------------

// The quest block (CGObjPC +0x217c, READ): a mask a quest sets
// (QB_ForceBlockOperation, slot 143, s:0x4ddd10) and releases
// (QB_ReleaseBlockedJob, slot 144, s:0x4ddd20); QB_IsBlocked (slot 145,
// s:0x4ddd30) tests it. It starts at 0 with the character (s:0x4dea6b). The
// stall's bit is 0x200: the open refuses 0x3c32 (s:0x515f4c..0x515f6a), the enter
// 0x3c33 (s:0x5162a9..0x5162c8). READ: the only setter's callers, every vtable call
// through +0x23c, set 0x60000 -- CQuestAType slot 36 (s:0x921ce0, shared by
// 167 quest classes) and CQNO_WC_PRIEST3_1 (s:0x899370) -- so no quest of
// this server sets 0x200 and the two refusals cannot happen in retail. OURS:
// the GM's /questblock sets any mask (a test tool).
const QuestBlockStall uint32 = 0x200

var questBlocks = struct {
	mu   sync.Mutex
	mask map[int64]uint32
}{mask: map[int64]uint32{}}

// QuestBlockSet ORs mask into characterID's quest block (slot 143) and
// returns the block.
func QuestBlockSet(characterID int64, mask uint32) uint32 {
	questBlocks.mu.Lock()
	defer questBlocks.mu.Unlock()
	questBlocks.mask[characterID] |= mask
	return questBlocks.mask[characterID]
}

// QuestBlockRelease clears mask from characterID's quest block (slot 144).
func QuestBlockRelease(characterID int64, mask uint32) uint32 {
	questBlocks.mu.Lock()
	defer questBlocks.mu.Unlock()
	m := questBlocks.mask[characterID] &^ mask
	if m == 0 {
		delete(questBlocks.mask, characterID)
	} else {
		questBlocks.mask[characterID] = m
	}
	return m
}

// questBlocked is QB_IsBlocked (slot 145).
func questBlocked(characterID int64, mask uint32) bool {
	questBlocks.mu.Lock()
	defer questBlocks.mu.Unlock()
	return questBlocks.mask[characterID]&mask != 0
}

// questBlockReset drops a leaving character's block (the next PC starts at
// 0, s:0x4dea6b).
func questBlockReset(characterID int64) {
	questBlocks.mu.Lock()
	defer questBlocks.mu.Unlock()
	delete(questBlocks.mask, characterID)
}

// --- the refusals OpenSRO has no state for -------------------------------------

// stallMurderer is 0x70B1's murderer test (s:0x515fe5: chardata+0xc, the PvP
// state, == 2 -> 0x3c39). OPEN: OpenSRO has no open-world PvP, so nobody is
// a murderer; this is the one place the state goes when it exists.
func stallMurderer(e world.Entity) bool { return false }

// stallWorldRefuses is the world controller's half of FUN_00515d10: the
// battle arena and the flag world refuse a stall (PC slot 0x670/0x660 ->
// s:0x559c70 returns 0 -> 0x3c16, for the open and the enter alike). OPEN:
// OpenSRO has neither world; this is where they answer when they exist.
func stallWorldRefuses(e world.Entity) bool { return false }

// stallTitleRefused is the title's word filter (c:0x8c3f10, f4's lists of
// the operator's AbuseFilter.txt, -abuse-filter): the original runs it only
// in the client, before 0x70B1 or type 7 is sent; OURS, the server runs it
// too, answering 0x3c38 -- the code the client shows for it.
func stallTitleRefused(title string) bool {
	f := NameFilter()
	return f != nil && !f.StallTitleOK(title)
}

// gmRestrictions is gm.RestrictionControl (round 840).
type gmRestrictions struct{ hub *world.Hub }

func (gmRestrictions) RestrictionsChanged(accountID int64) { ForgetRestrictions(accountID) }

func (g gmRestrictions) QuestBlock(name string, mask uint32, clear bool) (uint32, string, bool) {
	if g.hub == nil {
		return 0, "", false
	}
	e, ok := g.hub.FindByName(name)
	if !ok {
		for _, x := range g.hub.AllEntities() {
			if strings.EqualFold(x.Name, name) {
				e, ok = x, true
				break
			}
		}
	}
	if !ok {
		return 0, "", false
	}
	if clear {
		return QuestBlockRelease(e.CharacterID, mask), e.Name, true
	}
	return QuestBlockSet(e.CharacterID, mask), e.Name, true
}
