package session

// The private-server service scrolls (round 838). Every one is OURS: the
// archive's mall sells them (a Pandora/vPlus private server's own rows:
// ITEM_ANTHEIA_*, ITEM_NAME_COLOR_*, ITEM_TITLE_COLOR_*, the starter
// packages, the removers ...), but what they did was that server's filter,
// which no binary here holds. Each is built to its in-game description
// (textdata_object, read in full on the render box), and where the
// description leaves a choice open the conservative one is taken and named
// below. Nothing here is retail behaviour.
//
// Eight of them are typed 3/3/3/1 -- the return scroll's kind -- and before
// this round the dispatch cast each as a RETURN SCROLL and sent the player
// home (useitem.go's IsReturnScroll). They are now caught by code name before
// the return scroll, and only the Skill Reset Scroll goes home, because its
// description says so.
//
// The rules every one follows:
//   - The refusals come first, the item is kept on every one of them, and
//     the reply's Error says why (the client prints it as a system line).
//   - The item is spent in the same transaction as the effect when the
//     effect is a store write (silk, chest, pending flags, skills), so one
//     never lands without the other.
//   - An accepted use answers OpUseItemResult with the stack left, then
//     OpServiceLine with a line saying what happened.
//
// The messages, OURS (OpenSRO's own low range; 0x0138..0x013B were free in
// internal/session, internal/proto, internal/mall and the client's net/):
//
//	S->C 0x0138 {str text}                        a system line about a service
//	C->S 0x0139 {str name, str newName}           a pending rename, at character select
//	S->C 0x013A {u8 result, u16 code, str name}   1 renamed (name = the new one), 2 refused
//	S->C 0x013B {u32 uid, u32 name, u32 title}    a character's plate colours, 0xAARRGGBB, 0 = default
//
// and OpStartResult's code StartErrRenamePending: Start refused because the
// character's rename is waiting.

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"log/slog"
	"math/rand/v2"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/berserk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/buff"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/cos"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/friend"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/leveldata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/magicopt"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mall"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/pcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/skill"
	"github.com/TheOpenSRO/OpenSRO/server/internal/species"
	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// The service messages (OURS, see the file comment).
const (
	OpServiceLine  uint16 = 0x0138
	OpRename       uint16 = 0x0139
	OpRenameResult uint16 = 0x013A
	OpPlateColours uint16 = 0x013B
	// StartErrRenamePending is OpStartResult's code for a character whose
	// rename waits (OURS; outside every lobby code the client maps).
	StartErrRenamePending uint16 = 0x04F0
	// RenameErrNotPending is OpRenameResult's code for a character with no
	// rename waiting (OURS).
	RenameErrNotPending uint16 = 0x04F1
	renameOK            byte   = 1
	renameFail          byte   = 2
)

// ServiceDeps is what the service scrolls read and write. The silk, the
// chest, the lottery and the exchange are the mall's (mallRT); the jobs and
// the guilds their handlers' (jobRT, guildOps).
type ServiceDeps struct {
	Chars character.Store
	Inv   inventory.Store
	Items ItemLookup
	// Refs are the skill rows (the resets' SP and the leveler's list): a
	// SkillRefStore that can also list every row (refdata's stores).
	Refs   SkillRefStore
	Skills skill.Store // the raw store: a reset needs its Forgetter
	Equip  equipment.Store
	Hub    *world.Hub
	Keeper *CompositeKeeper
	Zerk   *berserk.Tracker
	// Options is the magic option table the Red Stats Remover reads the
	// signs from; nil refuses it.
	Options *magicopt.Table
	Parties *party.Hub
	Friends friend.Store
	Logger  *slog.Logger
	// Roll answers a number in [0, n); nil is math/rand/v2.
	Roll func(n int64) int64
	// Now is the clock; nil is time.Now.
	Now func() time.Time
}

var serviceRT atomic.Pointer[ServiceDeps]

func (d *ServiceDeps) logger() *slog.Logger {
	if d.Logger != nil {
		return d.Logger
	}
	return slog.Default()
}

func (d *ServiceDeps) roll(n int64) int64 {
	if n <= 0 {
		return 0
	}
	if d.Roll != nil {
		return d.Roll(n)
	}
	return rand.Int64N(n)
}

func (d *ServiceDeps) now() time.Time {
	if d.Now != nil {
		return d.Now()
	}
	return time.Now()
}

// ServiceHandler makes d the service scrolls' and serves the rename request
// (0x0139) a character select sends.
func ServiceHandler(d ServiceDeps) gateway.Handler {
	dd := d
	serviceRT.Store(&dd)
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode == OpRename {
			return dd.rename(ctx, sess, p.Data)
		}
		return nil
	}
}

// --- the kinds -----------------------------------------------------------------

type serviceKind int

const (
	svcSilk serviceKind = iota + 1
	svcDice
	svcJobPenalty
	svcGuildPenalty
	svcPremium
	svcRedStats
	svcSkillReset
	svcStatReset
	svcStatSkillReset
	svcSkillLeveler
	svcNameChange
	svcNameColour
	svcTitleColour
	svcStarter
	svcPetLevel
)

// serviceScroll is what one scroll does: its kind and the kind's argument.
type serviceScroll struct {
	kind   serviceKind
	amount int64
	colour uint32
	pack   []starterItem
}

// The plate colours (OURS, chosen from the item names; 0xAARRGGBB). The
// defaults are the plates' own READ colours: the name's white
// (World3D PLAYER_NAME_COLOUR, c:0x9cfd50) and the title's yellow #FFE65B
// (JOB_TITLE_COLOUR, c:0x9c28ed) -- "resets the color of your title to
// yellow" -- so a reset stores 0 and the plate draws its default.
var plateColourByName = map[string]uint32{
	"SKY":       0xFF87CEEB, // sky blue, the CSS/X11 SkyBlue
	"RED":       0xFFFF2020, // red, a touch off pure so it reads on the box
	"PURPLE":    0xFFA040FF, // purple, lightened from X11 purple (#A020F0) for the dark box
	"PINK":      0xFFFF69B4, // HotPink
	"ORANGE":    0xFFFFA500, // CSS orange
	"LIME":      0xFF32FF32, // lime green
	"DARKGREEN": 0xFF00802B, // a dark green that still reads on the box
	"BLUE":      0xFF3070FF, // blue, lightened from #0000FF, which is unreadable on the box
	"BLACK":     0xFF000000, // black
	"ARSENIC":   0xFF3B444B, // the named colour Arsenic
	"ANTIQUE":   0xFFCD9575, // Antique Brass ("Antique White" would be the default white)
	"WHITE":     0xFFFFFFFF, // white (the archive has a name one too, ITEM_NAME_COLOR_WHITE, not sold)
}

// silkScrollPrefix names the silk scrolls: ITEM_ANTHEIA_SILK_SCROLL_<n>.
const silkScrollPrefix = "ITEM_ANTHEIA_SILK_SCROLL_"

// luckyDiceMax is the Lucky Dice's top: "a random amount of silks ranging
// between 0 and 500" -- 0 and 500 both possible, evenly (OURS: no weighting
// is given).
const luckyDiceMax = 500

// serviceScrollOf reports whether it is one of the service scrolls, and what
// it does, by its code name (the rows carry nothing else that tells them
// apart: the removers share one Param block with the return scroll).
func serviceScrollOf(it *refdata.Item) (serviceScroll, bool) {
	if it == nil {
		return serviceScroll{}, false
	}
	code := strings.ToUpper(it.CodeName)
	switch code {
	case "ITEM_SILK_LOTTERY":
		return serviceScroll{kind: svcDice}, true
	case "ITEM_JOB_REMOVER":
		return serviceScroll{kind: svcJobPenalty}, true
	case "ITEM_GUILD_REMOVER":
		return serviceScroll{kind: svcGuildPenalty}, true
	case "ITEM_REMOVEPREM":
		return serviceScroll{kind: svcPremium}, true
	case "ITEM_DURABILITY_REMOVER":
		return serviceScroll{kind: svcRedStats}, true
	case "ITEM_ANTHEIA_SKILLRESET":
		return serviceScroll{kind: svcSkillReset}, true
	case "ITEM_ANTHEIA_STATRESET":
		return serviceScroll{kind: svcStatReset}, true
	case "ITEM_ETERNITY_STATSKILLRESET":
		return serviceScroll{kind: svcStatSkillReset}, true
	case "ITEM_ANTHEIA_MASTERY":
		return serviceScroll{kind: svcSkillLeveler}, true
	case "ITEM_NAME_CHANGE":
		return serviceScroll{kind: svcNameChange}, true
	case "ITEM_NAME_COLOR_RESET":
		return serviceScroll{kind: svcNameColour}, true
	case "ITEM_TITLE_COLOR_RESET":
		return serviceScroll{kind: svcTitleColour}, true
	case "ITEM_PET_LEVEL":
		return serviceScroll{kind: svcPetLevel}, true
	}
	if pack, ok := starterPackages[code]; ok {
		return serviceScroll{kind: svcStarter, pack: pack}, true
	}
	if n, ok := strings.CutPrefix(code, silkScrollPrefix); ok {
		if v, err := strconv.ParseInt(n, 10, 64); err == nil && v > 0 {
			return serviceScroll{kind: svcSilk, amount: v}, true
		}
		return serviceScroll{}, false
	}
	if c, ok := strings.CutPrefix(code, "ITEM_NAME_COLOR_"); ok {
		if argb, ok := plateColourByName[c]; ok {
			return serviceScroll{kind: svcNameColour, colour: argb}, true
		}
	}
	if c, ok := strings.CutPrefix(code, "ITEM_TITLE_COLOR_"); ok {
		if argb, ok := plateColourByName[c]; ok {
			return serviceScroll{kind: svcTitleColour, colour: argb}, true
		}
	}
	return serviceScroll{}, false
}

// --- the starter packages ---------------------------------------------------------

// starterItem is one line of a package's contents: the item (a man's and a
// woman's code where it goes by gender) and how many.
type starterItem struct {
	code, woman string
	n           int
}

// The packages' contents, from their descriptions ("The package contains:-
// 1-1x Premium GoldTime PLUS / 2-1x Devil's Spirit A grade / ..."), each line
// mapped to the archive's own row (MEASURED on the render box: textdata
// names and the rows the mall or the archive's own stores sell under them):
//
//	Premium GoldTime PLUS     ITEM_MALL_PREMIUM_VIETNAM_GOLDTIME_PLUS (the mall's "Premium GoldTime PLUS")
//	Devil's Spirit A grade    ITEM_MALL_AVATAR_M_NASRUN / _W_NASRUN (the mall's plain red one; by gender, OURS:
//	                          the description names no gender, but a spirit only fits its own)
//	Angel's Spirit A grade    ITEM_MALL_AVATAR_M_AMALRUN / _W_AMALRUN (likewise)
//	Angel Wing Dress          ITEM_AVATAR_M_ANGEL_WING_DRESS / _W_ (by gender: the archive's avatar store,
//	                          STORE_AVATARS_TAB1, sells these two)
//	Clock of Reincarnation    ITEM_COS_P_EXTENSION
//	Global Chatting           ITEM_MALL_GLOBAL_CHATTING
//	Reverse Return Scroll     ITEM_MALL_REVERSE_RETURN_SCROLL
//	Instant Return Scroll     ITEM_MALL_RETURN_SCROLL_HIGH_SPEED
//	Sabakun's Jewels          ITEM_ETC_NASRUN_ARCHEMY_UPGRADE_STONE ("Sabakun's jewel")
//	Devil's Spirit magicstone ITEM_MALL_NASRUN_ARCHEMY_MAGICSTONE_UMDU
//	SRO Lover Title           ITEM_TITLE_196 ("SRO Lover Title")
//	Buffalo                   ITEM_COS_T_BUFFALO_SCROLL
//	Lizard Trade Pet          ITEM_COS_T_CELESTIAL_LIZARD_SCROLL (the mall's "Lizard")
//	Repair Hammer             ITEM_MALL_REPAIR_HAMMER
//	Random Wing               ITEM_RANDOM_WING ("Random Wing Scroll")
var starterPackages = func() map[string][]starterItem {
	devil := starterItem{"ITEM_MALL_AVATAR_M_NASRUN", "ITEM_MALL_AVATAR_W_NASRUN", 1}
	angel := starterItem{"ITEM_MALL_AVATAR_M_AMALRUN", "ITEM_MALL_AVATAR_W_AMALRUN", 1}
	base := func(spirit starterItem, n int) []starterItem {
		return []starterItem{
			{"ITEM_MALL_PREMIUM_VIETNAM_GOLDTIME_PLUS", "", 1},
			spirit,
			{"ITEM_AVATAR_M_ANGEL_WING_DRESS", "ITEM_AVATAR_W_ANGEL_WING_DRESS", 1},
			{"ITEM_COS_P_EXTENSION", "", 1},
			{"ITEM_MALL_GLOBAL_CHATTING", "", n},
			{"ITEM_MALL_REVERSE_RETURN_SCROLL", "", n},
			{"ITEM_MALL_RETURN_SCROLL_HIGH_SPEED", "", n},
		}
	}
	special := func(spirit starterItem) []starterItem {
		return append(base(spirit, 22),
			starterItem{"ITEM_ETC_NASRUN_ARCHEMY_UPGRADE_STONE", "", 3},
			starterItem{"ITEM_MALL_NASRUN_ARCHEMY_MAGICSTONE_UMDU", "", 1},
			starterItem{"ITEM_TITLE_196", "", 1},
			starterItem{"ITEM_COS_T_BUFFALO_SCROLL", "", 5},
			starterItem{"ITEM_MALL_REPAIR_HAMMER", "", 11})
	}
	elite := func(spirit starterItem) []starterItem {
		return append(base(spirit, 22),
			starterItem{"ITEM_ETC_NASRUN_ARCHEMY_UPGRADE_STONE", "", 5},
			starterItem{"ITEM_MALL_NASRUN_ARCHEMY_MAGICSTONE_UMDU", "", 2},
			starterItem{"ITEM_TITLE_196", "", 1},
			starterItem{"ITEM_COS_T_CELESTIAL_LIZARD_SCROLL", "", 1},
			starterItem{"ITEM_MALL_REPAIR_HAMMER", "", 11},
			starterItem{"ITEM_RANDOM_WING", "", 1},
			starterItem{"ITEM_COS_T_BUFFALO_SCROLL", "", 5})
	}
	return map[string][]starterItem{
		"ITEM_STARTER_PACKAGE":                     base(devil, 11),
		"ITEM_STARTER_PACKAGE_ANGEL":               base(angel, 11),
		"ITEM_STARTER_PACKAGE_EXCLUSIVE":           special(devil),
		"ITEM_STARTER_PACKAGE_EXCLUSIVE_ANGEL":     special(angel),
		"ITEM_STARTER_PACKAGE_MOSTEXCLUSIVE":       elite(devil),
		"ITEM_STARTER_PACKAGE_MOSTEXCLUSIVE_ANGEL": elite(angel),
	}
}()

// starterFrom is the chest's "from" text for a package's items (OURS).
const starterFrom = "Starter Package"

// --- the use ----------------------------------------------------------------------

// serviceLine sends one OpServiceLine.
func serviceLine(sess *gateway.Session, text string) {
	sendTo(sess, OpServiceLine, appendServiceStr(nil, text))
}

func appendServiceStr(out []byte, s string) []byte {
	if len(s) > 0xffff {
		s = s[:0xffff]
	}
	out = binary.LittleEndian.AppendUint16(out, uint16(len(s)))
	return append(out, s...)
}

// errServiceRefused carries a refusal out of a transaction.
type errServiceRefused struct{ reason string }

func (e errServiceRefused) Error() string { return e.reason }

// useServiceScroll runs one service scroll's use. The caller has resolved
// the character, the slot and the item, and refused a dead user.
func useServiceScroll(ctx context.Context, sess *gateway.Session, characterID int64, it *refdata.Item,
	held inventory.Slot, have int, svc serviceScroll) error {
	fail := func(reason string) error {
		return sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{Error: reason}).Encode()})
	}
	d := serviceRT.Load()
	if d == nil || d.Inv == nil || d.Chars == nil {
		return fail("that cannot be used here")
	}
	// Not during an established exchange (OURS): the scroll may be on the
	// table, and its effect (silk, the chest, a disconnect) is not the
	// exchange's to undo.
	if m := mallRT.Load(); m != nil && m.Trades.Established(characterID) {
		return fail("You cannot use that during an exchange.")
	}
	u := serviceUse{d: d, sess: sess, cid: characterID, it: it, held: held, have: have, fail: fail}
	switch svc.kind {
	case svcSilk:
		return u.silk(ctx, svc.amount)
	case svcDice:
		return u.silk(ctx, -1)
	case svcJobPenalty:
		return u.jobPenalty(ctx)
	case svcGuildPenalty:
		return u.guildPenalty(ctx)
	case svcPremium:
		return u.premium(ctx)
	case svcRedStats:
		return u.redStats(ctx)
	case svcSkillReset:
		return u.skillReset(ctx)
	case svcStatReset:
		return u.pendingReset(ctx, character.ServicePendingStatReset)
	case svcStatSkillReset:
		return u.pendingReset(ctx, character.ServicePendingStatReset|character.ServicePendingSkillReset)
	case svcSkillLeveler:
		return u.skillLeveler(ctx)
	case svcNameChange:
		return u.nameChange(ctx)
	case svcNameColour:
		return u.colour(ctx, svc.colour, false)
	case svcTitleColour:
		return u.colour(ctx, svc.colour, true)
	case svcStarter:
		return u.starter(ctx, svc.pack)
	case svcPetLevel:
		return u.petLevel(ctx)
	}
	return fail("that cannot be used")
}

// serviceUse is one use in flight.
type serviceUse struct {
	d    *ServiceDeps
	sess *gateway.Session
	cid  int64
	it   *refdata.Item
	held inventory.Slot
	have int
	fail func(string) error
}

// spend takes the scroll (inside the caller's transaction).
func (u serviceUse) spend(ctx context.Context) error {
	return u.d.Inv.RemoveItem(ctx, u.cid, u.held.Index, 1)
}

// run spends the scroll and runs effect in one transaction over stores; a
// refusal or a failure keeps the scroll and answers the reply's Error.
func (u serviceUse) run(ctx context.Context, effect func(ctx context.Context) error, stores ...any) (bool, error) {
	err := txn.For(append([]any{u.d.Inv}, stores...)...).Run(ctx, func(ctx context.Context) error {
		if err := u.spend(ctx); err != nil {
			return err
		}
		return effect(ctx)
	})
	var refused errServiceRefused
	if errors.As(err, &refused) {
		return false, u.fail(refused.reason)
	}
	if err != nil {
		u.d.logger().Warn("service scroll failed", "character", u.cid, "item", u.it.CodeName, "err", err)
		return false, u.fail("using failed")
	}
	return true, nil
}

// accepted answers the use: the stack left, then the line.
func (u serviceUse) accepted(line string) error {
	err := u.sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{
		Remaining: int32(u.have - 1), ItemID: uint32(u.it.ID)}).Encode()})
	if line != "" {
		serviceLine(u.sess, line)
	}
	u.d.logger().Info("service scroll used", "character", u.cid, "item", u.it.CodeName, "line", line)
	return err
}

// silk is the silk scrolls (amount) and the Lucky Dice (amount < 0: the roll).
//
// OURS, the balance: OWN silk. Every silk scroll is priced in own silk alone
// (refpricepolicyofitem device 2: 10 silk for the 10 Silk Scroll ...), so the
// scroll is own silk turned into an item a player can trade, and its use
// turns it back; gift silk would buy less (a good priced in own silk alone
// cannot take it). The Lucky Dice is own-silk priced too.
func (u serviceUse) silk(ctx context.Context, amount int64) error {
	m := mallRT.Load()
	acct, ok := AuthenticatedAccountID(u.sess)
	if m == nil || m.Silk == nil || !ok {
		return u.fail("silk cannot be added here")
	}
	dice := amount < 0
	if dice {
		amount = u.d.roll(luckyDiceMax + 1)
	}
	var after account.Silk
	if ok, err := u.run(ctx, func(ctx context.Context) error {
		if amount == 0 {
			return nil
		}
		var err error
		after, err = m.Silk.AddSilk(ctx, acct, account.SilkOwn, amount)
		return err
	}, m.Silk); !ok {
		return err
	}
	line := fmt.Sprintf("You have received %d silk.", amount)
	if dice {
		line = fmt.Sprintf("The Lucky Dice rolled %d: you have received %d silk.", amount, amount)
		if amount == 0 {
			line = "The Lucky Dice rolled 0: no silk this time."
		}
	}
	if err := u.accepted(line); err != nil {
		return err
	}
	if amount > 0 {
		// The mall's info block (round 837): 0x3153, the balances after.
		sendTo(u.sess, mall.OpSilk, mall.EncodeBalances(balancesOf(after)))
	}
	return nil
}

// jobPenalty is the Job Penalty Remover: the 7 days a job guild withdrawal
// bars a rejoin (jobs.PenaltySeconds, round 799) end now.
func (u serviceUse) jobPenalty(ctx context.Context) error {
	jd := jobDepsNow()
	if jd.store == nil {
		return u.fail("there are no jobs here")
	}
	rec := jobRecord(ctx, u.cid)
	if !rec.Penalized(u.d.now()) {
		return u.fail("You have no job penalty to remove.")
	}
	if err := u.spend(ctx); err != nil {
		return u.fail("using failed")
	}
	rec.PenaltyUntil = time.Time{}
	if err := saveJobRecord(ctx, jd, rec); err != nil {
		u.giveBack(ctx)
		return u.fail("using failed")
	}
	return u.accepted("Your job penalty has been removed: you may join a job guild again.")
}

// giveBack returns the spent scroll after an effect outside the spend's
// transaction failed (as useExpansion does).
func (u serviceUse) giveBack(ctx context.Context) {
	if err := u.d.Inv.AddItemInstance(ctx, u.cid, u.held.ItemID, 1, u.held.Instance()); err != nil {
		u.d.logger().Error("service scroll lost: the effect failed and the item could not be returned",
			"character", u.cid, "item", u.it.CodeName, "err", err)
	}
}

// guildPenalty is the Guild Penalty Remover: "You must have left your guild
// already before using this scroll!" -- refused in a guild; otherwise the 72
// hours a leave, an expel or a disband bar a new guild (guild.PenaltyDuration,
// round 822) end now.
func (u serviceUse) guildPenalty(ctx context.Context) error {
	g := guildOps.Load()
	if g == nil || g.guilds == nil {
		return u.fail("there are no guilds here")
	}
	if _, err := g.guilds.GuildIDOf(ctx, u.cid); err == nil {
		return u.fail("You must have left your guild already before using this scroll!")
	} else if !errors.Is(err, guild.ErrNotInGuild) {
		return u.fail("lookup failed")
	}
	if g.penaltyLeft(ctx, u.cid) <= 0 {
		return u.fail("You have no guild penalty to remove.")
	}
	if err := u.spend(ctx); err != nil {
		return u.fail("using failed")
	}
	if err := g.guilds.SetPenalty(ctx, u.cid, u.d.now()); err != nil {
		u.giveBack(ctx)
		return u.fail("using failed")
	}
	return u.accepted("Your guild penalty has been removed: you may join or create a guild again.")
}

// premiumBuffPrefix names a premium item's buff: SKILL_MALL_PRE_* (the
// USU1 entry of every ITEM_MALL_PREMIUM_* composite, round 632).
const premiumBuffPrefix = "SKILL_MALL_PRE_"

// premium is the Premium Remover (OURS: no description; the conservative
// reading of its name). "Premium" is what a Premium item (ITEM_MALL_PREMIUM_*,
// a composite) leaves running: its buff (SKILL_MALL_PRE_*) and its timed item
// grants (the UIL1 return scrolls). Both end; nothing else is touched.
func (u serviceUse) premium(ctx context.Context) error {
	var buffs []buff.Record
	for _, r := range buffBooks.Active(u.cid) {
		if ref, err := u.d.Refs.GetSkill(ctx, r.SkillID); err == nil && ref != nil &&
			strings.HasPrefix(strings.ToUpper(ref.BasicCode), premiumBuffPrefix) {
			buffs = append(buffs, r)
		}
	}
	now := useItemClock()
	var grants []*compositeGrant
	if u.d.Keeper != nil {
		for _, g := range u.d.Keeper.running(u.cid, now) {
			if from, err := u.d.Items.GetItem(ctx, g.scrollID); err == nil && from != nil && isPremiumItem(from) {
				grants = append(grants, g)
			}
		}
	}
	if len(buffs) == 0 && len(grants) == 0 {
		return u.fail("You have no premium to remove.")
	}
	if err := u.spend(ctx); err != nil {
		return u.fail("using failed")
	}
	if len(buffs) > 0 {
		l := buffLock(u.cid)
		l.Lock()
		for _, r := range buffs {
			if rec, res, sp := buffBooks.Cancel(u.cid, r.SkillID, r.Token); res == buff.Cancelled {
				broadcastBuffEnd(zoneOf(u.d.Hub, u.cid), u.cid, []buff.Record{rec}, sp)
			}
		}
		l.Unlock()
		character.InvalidateBonus(u.cid)
	}
	if len(grants) > 0 {
		u.d.Keeper.bind(u.cid, u.sess)
		for _, g := range grants {
			u.d.Keeper.end(u.cid, g.fillID)
		}
		_ = sendCompositeState(u.sess, u.d.Keeper, u.d.Zerk, u.cid, now)
	}
	if err := u.accepted("Your premium has been removed."); err != nil {
		return err
	}
	pushOwnerStats(u.cid)
	return nil
}

// isPremiumItem reports a Premium item: ITEM_MALL_PREMIUM_* and the like.
func isPremiumItem(it *refdata.Item) bool {
	return strings.Contains(strings.ToUpper(it.CodeName), "_PREMIUM_")
}

// redStatsSlot is the bag slot the Red Stats Remover works on: the first
// (OURS, the archive's own rule for its item scrolls: "The item has to be
// located in the first slot of your inventory" -- the Advanced Elixir
// Remover, the gender switcher, the set upgrade).
const redStatsSlot = 0

// redStats is the Red Stats Remover. Red stats are the negative magic
// options, the only two whose magicoption.txt AttrType is not '+'
// (MEASURED, the box's magicoptions export): MATTR_DEC_MAXDUR ('-@',
// "Max durability N% decrease", the flaw a failed elixir leaves -- alchemy's
// FUN_00506b60, READ) and MATTR_NOT_REPARABLE ('-', "Not repairable"). The
// scroll takes every one off the item in the first bag slot.
func (u serviceUse) redStats(ctx context.Context) error {
	if u.d.Options == nil {
		return u.fail("that cannot be used here")
	}
	bag, err := u.d.Inv.List(ctx, u.cid)
	if err != nil {
		return u.fail("lookup failed")
	}
	var target *inventory.Slot
	for i := range bag {
		if bag[i].Index == redStatsSlot {
			target = &bag[i]
		}
	}
	if target == nil || target.Index == u.held.Index {
		return u.fail("Put the item to clean in the first slot of your inventory.")
	}
	ref, err := u.d.Items.GetItem(ctx, target.ItemID)
	if err != nil || ref == nil || ref.TypeID1 != equipment.TypeItem || ref.TypeID2 != equipment.TypeEquipment {
		return u.fail("Put the item to clean in the first slot of your inventory.")
	}
	kept := make([]uint64, 0, len(target.MagParams))
	for _, p := range target.MagParams {
		if row := u.d.Options.ByID(inventory.MagParamOption(p)); row != nil && strings.HasPrefix(row.Sign, "-") {
			continue
		}
		kept = append(kept, p)
	}
	removed := len(target.MagParams) - len(kept)
	if removed == 0 {
		return u.fail("The item in the first slot of your inventory has no red stats.")
	}
	inst := target.Instance()
	inst.MagParams = kept
	if ok, err := u.run(ctx, func(ctx context.Context) error {
		return u.d.Inv.SetInstance(ctx, u.cid, target.Index, inst)
	}); !ok {
		return err
	}
	character.InvalidateBonus(u.cid)
	return u.accepted(fmt.Sprintf("%d red stat(s) removed from the item in the first slot of your inventory.", removed))
}

// learnedSkills is characterID's learned real skills -- rows with a learn
// cost; the defaults (base attacks, ReqLearnSP 0) are not -- and their SP.
func (d *ServiceDeps) learnedSkills(ctx context.Context, characterID int64) (ids []int64, sp int, err error) {
	known, err := d.Skills.KnownSkills(ctx, characterID)
	if err != nil {
		return nil, 0, err
	}
	for _, id := range known {
		ref, err := d.Refs.GetSkill(ctx, id)
		if err != nil || ref == nil || ref.ReqLearnSP <= 0 {
			continue
		}
		ids = append(ids, id)
		sp += ref.ReqLearnSP
	}
	return ids, sp, nil
}

// resetSkills forgets ids and refunds sp less the SP the Skill Leveler
// waived (inside the caller's transaction), returning what came back.
// OURS, the rule: every learned skill goes, each level's ReqLearn_SP (the
// cost the learn handler took, skilldata column 46) comes back; the mastery
// levels stay -- the descriptions name the skills alone. Skills the leveler
// opened free were never paid for, so their SP does not come back (or the
// two scrolls together would turn silk into SP).
func (d *ServiceDeps) resetSkills(ctx context.Context, characterID int64, ids []int64, sp int) (int, error) {
	f, ok := d.Skills.(skill.Forgetter)
	if !ok {
		return 0, errors.New("the skill store cannot forget")
	}
	for _, id := range ids {
		if err := f.Forget(ctx, characterID, id); err != nil {
			return 0, err
		}
	}
	if st, ok := d.Chars.(character.ServiceStore); ok {
		waived, err := st.TakeWaivedSP(ctx, characterID)
		if err != nil {
			return 0, err
		}
		sp = max(0, sp-int(waived))
	}
	if sp > 0 {
		if _, err := d.Skills.AddSkillPoints(ctx, characterID, sp); err != nil {
			return 0, err
		}
	}
	return sp, nil
}

// skillsChanged refreshes what learned skills feed and tells the client:
// the skill window's state (0x0076) and the stats (0x00EF).
func (d *ServiceDeps) skillsChanged(sess *gateway.Session, characterID int64) {
	invalidatePassives(characterID)
	character.InvalidateBonus(characterID)
	if r, why := buildSkillState(context.Background(), d.Chars, d.Skills, d.Refs, characterID); why == "" {
		sendTo(sess, OpSkillStateResult, r.Encode())
	}
	pushOwnerStats(characterID)
}

// skillReset is the Skill Reset Scroll: "Once you use this scroll, you will
// get teleported back to your appointed teleport area and your skills will
// get reset." The skills reset at once (resetSkills) and the character goes
// home as a return scroll's arrival does (warpHome), with no casting bar
// (OURS: the description names none). A scroll already working, or a trade
// cart, refuses it as either refuses the return scroll (round 778/801).
func (u serviceUse) skillReset(ctx context.Context) error {
	if u.d.Skills == nil || u.d.Refs == nil || u.d.Hub == nil {
		return u.fail("that cannot be used here")
	}
	if s := activeScrolls.Load(); s != nil && s.Casting(u.cid) {
		return scrollRefusal(u.sess, ScrollErrAlreadyWorking, scrollReason(ScrollErrAlreadyWorking))
	}
	if ownsTransport(u.cid) {
		return scrollRefusal(u.sess, ScrollErrCart, "you cannot teleport with a trade cart")
	}
	ids, sp, err := u.d.learnedSkills(ctx, u.cid)
	if err != nil {
		return u.fail("lookup failed")
	}
	if len(ids) == 0 {
		return u.fail("You have no skills to reset.")
	}
	if ok, err := u.run(ctx, func(ctx context.Context) (err error) {
		sp, err = u.d.resetSkills(ctx, u.cid, ids, sp)
		return err
	}, u.d.Skills, u.d.Chars); !ok {
		return err
	}
	if err := u.accepted(fmt.Sprintf("Your skills have been reset: %d SP returned.", sp)); err != nil {
		return err
	}
	u.d.skillsChanged(u.sess, u.cid)
	_, _ = warpHome(ctx, u.sess, u.d.Equip, u.d.Chars, u.d.Hub, u.d.Zerk, "skill reset scroll")
	return nil
}

// pendingReset is the Stat Reset Scroll and the Skill & Stat Reset Scroll:
// "you will have to relog for your stats to get reset and once you relogin,
// your stats will be reset." The use stores the reset; the next entry runs
// it (serviceAtEntry). A reset already waiting refuses a second scroll.
func (u serviceUse) pendingReset(ctx context.Context, flags uint32) error {
	st, ok := u.d.Chars.(character.ServiceStore)
	if !ok {
		return u.fail("that cannot be used here")
	}
	if p, err := st.ServicePending(ctx, u.cid); err != nil {
		return u.fail("lookup failed")
	} else if p&flags == flags {
		return u.fail("A reset is already waiting for your next login.")
	}
	if ok, err := u.run(ctx, func(ctx context.Context) error {
		_, err := st.AddServicePending(ctx, u.cid, flags)
		return err
	}, u.d.Chars); !ok {
		return err
	}
	line := "Relog to reset your stats: they will be reset when you log in again."
	if flags&character.ServicePendingSkillReset != 0 {
		line = "Relog to reset your stats and skills: they will be reset when you log in again."
	}
	return u.accepted(line)
}

// skillLevelerPlan is every skill the character's mastery levels open and it
// does not know, in an order the learn rules accept (each level after the
// one below it, each prerequisite before what needs it).
//
// The filter is LearnSkillHandler's, in its order, without the SP: a row
// with a learn cost, of a mastery the character holds, at or under that
// mastery's level (and the second mastery's, when a row names one -- OURS,
// stricter than the handler, which reads only the first), of the
// character's race, with its chain and prerequisites met.
func (d *ServiceDeps) skillLevelerPlan(ctx context.Context, c *character.Character) ([]int64, error) {
	all, ok := d.Refs.(interface {
		ListAllSkills(ctx context.Context) ([]*refdata.Skill, error)
	})
	if !ok {
		return nil, errors.New("the skill rows cannot be listed")
	}
	rows, err := all.ListAllSkills(ctx)
	if err != nil {
		return nil, err
	}
	levels, err := d.Skills.MasteryLevels(ctx, c.ID)
	if err != nil {
		return nil, err
	}
	known, err := d.Skills.KnownSkills(ctx, c.ID)
	if err != nil {
		return nil, err
	}
	country := characterCountry(c)
	have := map[int64]bool{}
	for _, id := range known {
		have[id] = true
	}
	var cands []*refdata.Skill
	for _, r := range rows {
		if r == nil || have[r.ID] || r.ReqLearnSP <= 0 || r.Mastery1 <= 0 || !skill.HoldsMastery(country, r.Mastery1) {
			continue
		}
		if levels[r.Mastery1] < r.MasteryLevel1 || !skill.LearnRaceAllows(r.ReqLearnRace, country) {
			continue
		}
		if r.Mastery2 > 0 && levels[r.Mastery2] < r.MasteryLevel2 {
			continue
		}
		cands = append(cands, r)
	}
	sort.Slice(cands, func(i, j int) bool {
		if cands[i].BasicLevel != cands[j].BasicLevel {
			return cands[i].BasicLevel < cands[j].BasicLevel
		}
		return cands[i].ID < cands[j].ID
	})
	// learnPrerequisiteFailure over what is known plus what the plan has
	// taken so far, until a pass takes nothing more.
	var plan []int64
	ids := append([]int64(nil), known...)
	for progress := true; progress; {
		progress = false
		rest := cands[:0]
		for _, r := range cands {
			if learnPrerequisiteFailure(ctx, d.Refs, r, ids) == "" {
				plan = append(plan, r.ID)
				ids = append(ids, r.ID)
				progress = true
				continue
			}
			rest = append(rest, r)
		}
		cands = rest
	}
	return plan, nil
}

// skillLeveler is the Skill Leveler: "automatically open the available skills
// for each mastery you leveled up based on your mastery level." Every skill
// skillLevelerPlan finds is learned, FREE (OURS: the description charges
// nothing, and the scroll is the price); nothing to open refuses it. The SP
// the skills would have cost is recorded (AddWaivedSP), so a later skill
// reset does not refund it.
func (u serviceUse) skillLeveler(ctx context.Context) error {
	if u.d.Skills == nil || u.d.Refs == nil {
		return u.fail("that cannot be used here")
	}
	c, err := u.d.Chars.GetByID(ctx, u.cid)
	if err != nil || c == nil {
		return u.fail("lookup failed")
	}
	plan, err := u.d.skillLevelerPlan(ctx, c)
	if err != nil {
		u.d.logger().Warn("skill leveler: planning failed", "character", u.cid, "err", err)
		return u.fail("lookup failed")
	}
	if len(plan) == 0 {
		return u.fail("There are no skills to open for your mastery levels.")
	}
	if ok, err := u.run(ctx, func(ctx context.Context) error {
		var waived int64
		for _, id := range plan {
			if err := u.d.Skills.Learn(ctx, u.cid, id); errors.Is(err, skill.ErrAlreadyKnown) {
				continue
			} else if err != nil {
				return err
			}
			if ref, err := u.d.Refs.GetSkill(ctx, id); err == nil && ref != nil {
				waived += int64(ref.ReqLearnSP)
			}
		}
		if st, ok := u.d.Chars.(character.ServiceStore); ok && waived > 0 {
			return st.AddWaivedSP(ctx, u.cid, waived)
		}
		return nil
	}, u.d.Skills, u.d.Chars); !ok {
		return err
	}
	if err := u.accepted(fmt.Sprintf("%d skill level(s) have been opened for your masteries.", len(plan))); err != nil {
		return err
	}
	u.d.skillsChanged(u.sess, u.cid)
	return nil
}

// The name change's refusals: retail's own name-change texts (textuisystem
// UIIT_MSG_ITEM_CHANGE_NAME_CANCLE_*: retail has a rename item of its own,
// whose restrictions these are; useServiceScroll refuses an open exchange for every
// scroll).
const (
	nameChangeJobSuit = "You cannot use character name change items while wearing a Job outfit."
	nameChangeParty   = "You cannot use character name change items while in a party or while registered for party matching."
)

// nameChange is the Name Change Scroll: "allow you to change your name on
// your next login. NOTE: The scroll is going to immediately disconnect you
// upon usage!" The use stores the rename and ends the session; the next
// Start of that character is refused (StartErrRenamePending) and the select
// screen asks for the new name (OpRename).
func (u serviceUse) nameChange(ctx context.Context) error {
	st, ok := u.d.Chars.(character.ServiceStore)
	if !ok {
		return u.fail("that cannot be used here")
	}
	if p, err := st.ServicePending(ctx, u.cid); err != nil {
		return u.fail("lookup failed")
	} else if p&character.ServicePendingRename != 0 {
		return u.fail("A name change is already waiting for your next login.")
	}
	if wornJobState(ctx, u.cid) != pcspawn.JobStateNone {
		return u.fail(nameChangeJobSuit)
	}
	if u.d.Parties != nil {
		if _, in := u.d.Parties.Get(u.cid); in {
			return u.fail(nameChangeParty)
		}
		if _, _, listed := u.d.Parties.Listing(u.cid); listed {
			return u.fail(nameChangeParty)
		}
	}
	if ok, err := u.run(ctx, func(ctx context.Context) error {
		_, err := st.AddServicePending(ctx, u.cid, character.ServicePendingRename)
		return err
	}, u.d.Chars); !ok {
		return err
	}
	if err := u.accepted("Your name will be changed at your next login. Disconnecting..."); err != nil {
		return err
	}
	// "immediately disconnect you": the session ends once the two replies
	// are written (gateway.ErrEndSession drains first).
	return gateway.ErrEndSession
}

// colour is the name and title colour scrolls: the colour stored, the
// plate's 0x013B to everyone who sees the character (the character too).
func (u serviceUse) colour(ctx context.Context, argb uint32, title bool) error {
	st, ok := u.d.Chars.(character.ServiceStore)
	if !ok {
		return u.fail("that cannot be used here")
	}
	name, tit, err := st.PlateColours(ctx, u.cid)
	if err != nil {
		return u.fail("lookup failed")
	}
	cur, what := name, "name"
	if title {
		cur, what = tit, "title"
	}
	if cur == argb {
		return u.fail(fmt.Sprintf("Your %s already has that colour.", what))
	}
	if ok, err := u.run(ctx, func(ctx context.Context) error {
		if title {
			return st.SetTitleColour(ctx, u.cid, argb)
		}
		return st.SetNameColour(ctx, u.cid, argb)
	}, u.d.Chars); !ok {
		return err
	}
	if title {
		tit = argb
	} else {
		name = argb
	}
	notePlateColours(u.cid, name, tit)
	line := fmt.Sprintf("Your %s colour has been changed.", what)
	if argb == 0 {
		line = fmt.Sprintf("Your %s colour has been reset.", what)
	}
	if err := u.accepted(line); err != nil {
		return err
	}
	if u.d.Hub != nil {
		sendAboutOwner(equipObservers(u.d.Hub, u.cid), u.cid, OpPlateColours, encodePlateColours(u.cid, name, tit))
	}
	return nil
}

// starter is the starter packages: "Right Click to activate - Check Chest
// for Items !" ... "You will receive the package contents in your Item
// Chest." Every line of the contents goes to the item chest (round 837),
// split into stacks the item's MaxStack allows, the gendered lines by the
// character's sex. A line the item table lacks refuses the whole package.
func (u serviceUse) starter(ctx context.Context, pack []starterItem) error {
	m := mallRT.Load()
	byCode, ok := u.d.Items.(itemByCode)
	if m == nil || m.Store == nil || !ok {
		return u.fail("the item chest is not available here")
	}
	c, err := u.d.Chars.GetByID(ctx, u.cid)
	if err != nil || c == nil {
		return u.fail("lookup failed")
	}
	woman := character.SexOf(c.Gender) == character.SexWoman
	now := u.d.now()
	var entries []mall.ChestEntry
	for _, line := range pack {
		code := line.code
		if woman && line.woman != "" {
			code = line.woman
		}
		ref, err := byCode.GetItemByCode(ctx, code)
		if err != nil || ref == nil {
			u.d.logger().Warn("starter package: an item is not in the table", "code", code, "err", err)
			return u.fail("This package cannot be opened on this server.")
		}
		stack := max(ref.MaxStack, 1)
		for left := line.n; left > 0; left -= stack {
			entries = append(entries, mall.ChestEntry{Owner: u.cid, ItemID: ref.ID, Quantity: min(left, stack),
				From: starterFrom, At: now})
		}
	}
	if ok, err := u.run(ctx, func(ctx context.Context) error {
		for i := range entries {
			id, err := m.Store.AddToChest(ctx, entries[i])
			if err != nil {
				return err
			}
			entries[i].ID = id
		}
		return nil
	}, m.Store); !ok {
		return err
	}
	if err := u.accepted("The package has been opened: its items are in your Item Chest."); err != nil {
		return err
	}
	for _, e := range entries {
		sendTo(u.sess, mall.OpChestReceived, mall.EncodeChestReceived(e.ItemID, e.Quantity))
	}
	return nil
}

// petLevel is Pet Level Up: "A scroll that will upgrade your pet's level to
// your character's current level." The summoned growth pet (the only kind
// with a level, cosexp.go) is raised to the character's level -- capped at
// cos.PetMaxLevel, the last row -- along its own rows, as its EXP level-ups
// go (cosGainExp), with its EXP at 0 of the new level. OURS: the EXP
// level-up's stop at 110 (cos.PetLevelsUp) is not applied, the description
// names the character's level. No growth pet out, or one already there,
// refuses it.
func (u serviceUse) petLevel(ctx context.Context) error {
	if levelTable == nil {
		return u.fail("that cannot be used here")
	}
	c, err := u.d.Chars.GetByID(ctx, u.cid)
	if err != nil || c == nil {
		return u.fail("lookup failed")
	}
	var pet *cosObj
	for _, o := range cosWorld.owned(u.cid) {
		cosWorld.mu.Lock()
		growth, dead := o.kind == cos.KindGrowth, o.dead
		cosWorld.mu.Unlock()
		if growth && !dead {
			pet = o
		}
	}
	if pet == nil {
		return u.fail("Summon the pet you want to level up first.")
	}
	target := min(c.Level, cos.PetMaxLevel)
	cosWorld.mu.Lock()
	level, exp, row := pet.rec.Level, pet.rec.Exp, pet.row
	cosWorld.mu.Unlock()
	if level >= target {
		return u.fail("Your pet is already at your level.")
	}
	// The rows first, so a broken chain refuses before the scroll is spent.
	var rows []species.Row
	var delta int64
	for l := level; l < target; l++ {
		next, _ := levelTable.ExpToNext(l)
		nr, ok := cosRowByCode(row.DescStrID)
		if next <= 0 || !ok || nr.TypeID4 != pet.kind {
			break
		}
		if l == level {
			delta += next - exp
		} else {
			delta += next
		}
		rows = append(rows, nr)
		row = nr
	}
	if len(rows) == 0 {
		return u.fail("Your pet cannot grow any further.")
	}
	if err := u.spend(ctx); err != nil {
		return u.fail("using failed")
	}
	cosWorld.mu.Lock()
	last := rows[len(rows)-1]
	pet.row = last
	pet.rec.Level, pet.rec.Exp = level+len(rows), 0
	pet.rec.RefCharID, pet.rec.HP, pet.rec.HGP = last.ID, last.MaxHP, cos.HGPFull
	reached, uid := pet.rec.Level, pet.uid
	cosWorld.mu.Unlock()
	if err := u.accepted(fmt.Sprintf("Your pet has reached level %d.", reached)); err != nil {
		return err
	}
	// The client walks the same thresholds on this EXP (FUN_008aa340,
	// hud_cos apply_exp_delta) and lands on the same level at 0.
	sendToCOSOwner(pet, cos.OpCOSUpdate, cos.ExpUpdate(uid, delta, 0))
	for _, r := range rows {
		sendAboutCOS(pet, cos.OpCOSUpdate, cos.RefUpdate(uid, uint32(r.ID)))
		sendAboutCOS(pet, cos.OpCOSLevelUp, uint32LE(uid))
	}
	bumpPlayerState(u.cid)
	cosSave(ctx, pet)
	return nil
}

// --- the plate colours ---------------------------------------------------------------

// plateColours caches each character's colours (int64 -> [2]uint32), filled
// at world entry and on a change, so a spawn never reads the store.
var plateColours sync.Map

// notePlateColours caches a character's colours.
func notePlateColours(characterID int64, name, title uint32) {
	if name == 0 && title == 0 {
		plateColours.Delete(characterID)
		return
	}
	plateColours.Store(characterID, [2]uint32{name, title})
}

func encodePlateColours(characterID int64, name, title uint32) []byte {
	out := binary.LittleEndian.AppendUint32(nil, uint32(characterID))
	out = binary.LittleEndian.AppendUint32(out, name)
	return binary.LittleEndian.AppendUint32(out, title)
}

// plateColourFrame is characterID's 0x013B for its spawn, nil with the
// default colours.
func plateColourFrame(characterID int64) *gateway.Frame {
	v, ok := plateColours.Load(characterID)
	if !ok {
		return nil
	}
	c := v.([2]uint32)
	return gateway.MustFrame(&proto.Packet{Opcode: OpPlateColours, Data: encodePlateColours(characterID, c[0], c[1])})
}

// --- the next login ----------------------------------------------------------------------

// serviceLines holds the lines an entry's resets leave for the arrival
// (serviceAfterEnter), keyed by character.
var serviceLines sync.Map

// serviceAtEntry runs at the top of the world entry (enterOwned), before the
// character is placed: it caches the plate colours and runs a pending stat or
// skill reset (ITEM_ANTHEIA_STATRESET, ITEM_ETERNITY_STATSKILLRESET),
// returning the character re-read when a reset changed it.
func serviceAtEntry(ctx context.Context, chars character.Store, owned *character.Character) *character.Character {
	st, ok := chars.(character.ServiceStore)
	if !ok {
		return owned
	}
	if name, title, err := st.PlateColours(ctx, owned.ID); err == nil {
		notePlateColours(owned.ID, name, title)
	}
	pending, err := st.ServicePending(ctx, owned.ID)
	if err != nil {
		return owned
	}
	pending &= character.ServicePendingStatReset | character.ServicePendingSkillReset
	if pending == 0 {
		return owned
	}
	d := serviceRT.Load()
	var lines []string
	if pending&character.ServicePendingStatReset != 0 {
		if line, err := resetStats(ctx, chars, owned.ID); err != nil {
			slog.Warn("service: the stat reset failed", "character", owned.ID, "err", err)
			pending &^= character.ServicePendingStatReset
		} else {
			lines = append(lines, line)
		}
	}
	if pending&character.ServicePendingSkillReset != 0 {
		if d == nil || d.Skills == nil || d.Refs == nil {
			pending &^= character.ServicePendingSkillReset
		} else if ids, sp, err := d.learnedSkills(ctx, owned.ID); err != nil {
			pending &^= character.ServicePendingSkillReset
		} else if err := txn.For(d.Skills, d.Chars).Run(ctx, func(ctx context.Context) (err error) {
			sp, err = d.resetSkills(ctx, owned.ID, ids, sp)
			return err
		}); err != nil {
			slog.Warn("service: the skill reset failed", "character", owned.ID, "err", err)
			pending &^= character.ServicePendingSkillReset
		} else {
			invalidatePassives(owned.ID)
			lines = append(lines, fmt.Sprintf("Your skills have been reset: %d SP returned.", sp))
		}
	}
	if pending != 0 {
		if _, err := st.ClearServicePending(ctx, owned.ID, pending); err != nil {
			slog.Warn("service: clearing a done reset failed", "character", owned.ID, "err", err)
		}
	}
	character.InvalidateBonus(owned.ID)
	clampHP(ctx, chars, owned.ID)
	if len(lines) > 0 {
		serviceLines.Store(owned.ID, lines)
	}
	if again, err := chars.GetByID(ctx, owned.ID); err == nil && again != nil {
		return again
	}
	return owned
}

// resetStats is the stat reset: Str and Int back to a fresh character's at
// this level, the points every level gave back to spend -- the game's own
// rule (GObjPC_SetLevel 0x004e4d90, round 692: 20 and 20 at level 1, each
// level +1 Str, +1 Int and leveldata.StatPointsPerLevel to spend).
func resetStats(ctx context.Context, chars character.Store, characterID int64) (string, error) {
	unlock := character.LockLeveling(characterID)
	defer unlock()
	c, err := chars.GetByID(ctx, characterID)
	if err != nil || c == nil {
		return "", fmt.Errorf("reading the character: %w", err)
	}
	gained := max(c.Level-1, 0)
	str := character.StartingStr + gained*character.StatGrowthPerLevel
	intel := character.StartingInt + gained*character.StatGrowthPerLevel
	points := gained * leveldata.StatPointsPerLevel
	if err := chars.SetLeveling(ctx, characterID, c.Level, c.Exp, points, str, intel); err != nil {
		return "", err
	}
	return fmt.Sprintf("Your stats have been reset: Str %d, Int %d, %d stat points to spend.", str, intel, points), nil
}

// serviceAfterEnter runs after the arrival's OpSelfID: the character's own
// plate colours, and the lines the entry's resets left.
func serviceAfterEnter(sess *gateway.Session, owned *character.Character) {
	if v, ok := plateColours.Load(owned.ID); ok {
		c := v.([2]uint32)
		sendTo(sess, OpPlateColours, encodePlateColours(owned.ID, c[0], c[1]))
	}
	if v, ok := serviceLines.LoadAndDelete(owned.ID); ok {
		for _, line := range v.([]string) {
			serviceLine(sess, line)
		}
	}
}

// startRefusalForService is Start's test (handleStart): a character whose
// rename waits is refused StartErrRenamePending, which the select screen
// answers with the new name (OpRename); 0 lets it in.
func startRefusalForService(ctx context.Context, chars character.Store, characterID int64) uint16 {
	st, ok := chars.(character.ServiceStore)
	if !ok {
		return 0
	}
	if p, err := st.ServicePending(ctx, characterID); err == nil && p&character.ServicePendingRename != 0 {
		return StartErrRenamePending
	}
	return 0
}

// --- the rename at character select --------------------------------------------------------

// RenameRequest is 0x0139.
type RenameRequest struct {
	Name, NewName string
}

func (r *RenameRequest) Encode() []byte {
	return appendServiceStr(appendServiceStr(nil, r.Name), r.NewName)
}

// DecodeRenameRequest reads 0x0139.
func DecodeRenameRequest(b []byte) (*RenameRequest, error) {
	f, _, err := decodeStringsPrefix(b, 2)
	if err != nil {
		return nil, fmt.Errorf("session: decoding RenameRequest: %w", err)
	}
	return &RenameRequest{Name: f[0], NewName: f[1]}, nil
}

// EncodeRenameResult is 0x013A.
func EncodeRenameResult(ok bool, code uint16, name string) []byte {
	res := renameFail
	if ok {
		res = renameOK
	}
	out := binary.LittleEndian.AppendUint16([]byte{res}, code)
	return appendServiceStr(out, name)
}

// rename answers 0x0139: the character must be on the session's account,
// out of the world, with a rename waiting; the new name passes creation's
// rules (LobbyNameCode: 2..12 bytes, the name filter) and is no character's
// (NameTaken, the unique index). The name is changed, the flag cleared, and
// the two tables that keep a copy of it (the guild's member row, the friend
// lists' rows) follow.
func (d *ServiceDeps) rename(ctx context.Context, sess *gateway.Session, data []byte) error {
	reply := func(ok bool, code uint16, name string) error {
		return sess.Send(&proto.Packet{Opcode: OpRenameResult, Data: EncodeRenameResult(ok, code, name)})
	}
	acct, ok := AuthenticatedAccountID(sess)
	if !ok {
		return reply(false, LobbyErrNoUser, "")
	}
	req, err := DecodeRenameRequest(data)
	if err != nil {
		return reply(false, LobbyErrRefused, "")
	}
	if d.Hub != nil {
		if _, in := d.Hub.EntityBySession(sess.ID()); in {
			return reply(false, LobbyErrBusy, "")
		}
	}
	st, ok := d.Chars.(character.ServiceStore)
	lobby, okLobby := d.Chars.(character.LobbyStore)
	if !ok || !okLobby {
		return reply(false, LobbyErrRefused, "")
	}
	list, err := d.Chars.ListByAccount(ctx, acct)
	if err != nil {
		return reply(false, LobbyErrRefused, "")
	}
	owned := findOwned(list, req.Name)
	if owned == nil {
		return reply(false, LobbyErrNotOnAccount, "")
	}
	if p, err := st.ServicePending(ctx, owned.ID); err != nil || p&character.ServicePendingRename == 0 {
		return reply(false, RenameErrNotPending, "")
	}
	if code := LobbyNameCode(req.NewName); code != 0 {
		return reply(false, code, "")
	}
	if character.SameName(owned.Name, req.NewName) {
		return reply(false, LobbyErrNameExists, "")
	}
	if taken, err := lobby.NameTaken(ctx, req.NewName); err != nil {
		return reply(false, LobbyErrRefused, "")
	} else if taken {
		return reply(false, LobbyErrNameExists, "")
	}
	err = txn.For(d.Chars).Run(ctx, func(ctx context.Context) error {
		if err := st.Rename(ctx, owned.ID, req.NewName); err != nil {
			return err
		}
		_, err := st.ClearServicePending(ctx, owned.ID, character.ServicePendingRename)
		return err
	})
	if errors.Is(err, character.ErrNameTaken) {
		return reply(false, LobbyErrNameExists, "")
	}
	if err != nil {
		d.logger().Warn("rename failed", "character", owned.ID, "err", err)
		return reply(false, LobbyErrRefused, "")
	}
	// The copies of the name (best effort: the rename stands either way).
	if g := guildOps.Load(); g != nil {
		if r, ok := g.guilds.(guild.MemberRenamer); ok {
			if err := r.RenameMember(ctx, owned.ID, req.NewName); err != nil {
				d.logger().Warn("rename: the guild's member row kept the old name", "character", owned.ID, "err", err)
			}
		}
	}
	if r, ok := d.Friends.(friend.Renamer); ok {
		if err := r.RenameFriend(ctx, owned.ID, req.NewName); err != nil {
			d.logger().Warn("rename: the friend lists kept the old name", "character", owned.ID, "err", err)
		}
	}
	d.logger().Info("character renamed", "character", owned.ID, "from", owned.Name, "to", req.NewName)
	return reply(true, 0, req.NewName)
}

// --- the Silk Lottery ----------------------------------------------------------------------

// registerLottery is the purchase's registration (mall/lottery.go): one
// entry per ticket the plan makes, each weighted by its share of the silk
// the purchase took. Inside the purchase's transaction.
func registerLottery(ctx context.Context, store mall.Store, cid, acct int64, plan mall.Plan, at time.Time) error {
	ls, ok := store.(mall.LotteryStore)
	if !ok {
		return nil
	}
	var tickets []string
	for _, u := range plan.Units {
		if mall.IsLotteryTicket(u.Scrap.Item.Code) {
			for range max(u.Stack, 1) {
				tickets = append(tickets, u.Scrap.Item.Code)
			}
		}
	}
	if len(tickets) == 0 {
		return nil
	}
	each := plan.Pay.Silk() / int64(len(tickets))
	for _, code := range tickets {
		if err := ls.RegisterLottery(ctx, mall.LotteryEntry{AccountID: acct, CharacterID: cid, Ticket: code, Silk: each, At: at}); err != nil {
			return err
		}
	}
	return nil
}

// lotteryRegistered is the purchase's line after a ticket registered.
func lotteryRegistered(sess *gateway.Session, plan mall.Plan) {
	for _, u := range plan.Units {
		if mall.IsLotteryTicket(u.Scrap.Item.Code) {
			serviceLine(sess, "You have been registered for the Silk Lottery Event.")
			return
		}
	}
}

// gmLottery is /lottery's hook (gm.LotteryControl), over the mall's store.
type gmLottery struct{ hub *world.Hub }

func (g gmLottery) store() (mall.LotteryStore, *MallDeps, error) {
	m := mallRT.Load()
	if m == nil || m.Store == nil || m.Silk == nil {
		return nil, nil, errors.New("no mall")
	}
	ls, ok := m.Store.(mall.LotteryStore)
	if !ok {
		return nil, nil, errors.New("the mall's store keeps no lottery")
	}
	return ls, m, nil
}

// LotteryStatus implements gm.LotteryControl.
func (g gmLottery) LotteryStatus(ctx context.Context) (int, int64, error) {
	ls, _, err := g.store()
	if err != nil {
		return 0, 0, err
	}
	es, err := ls.OpenLottery(ctx)
	if err != nil {
		return 0, 0, err
	}
	var pot int64
	for _, e := range es {
		pot += e.Silk
	}
	return len(es), pot, nil
}

// LotteryDraw implements gm.LotteryControl.
func (g gmLottery) LotteryDraw(ctx context.Context, prize int64) (string, int64, int, error) {
	ls, m, err := g.store()
	if err != nil {
		return "", 0, 0, err
	}
	roll := func(n int64) int64 { return rand.Int64N(n) }
	if d := serviceRT.Load(); d != nil {
		roll = d.roll
	}
	var (
		won    mall.LotteryEntry
		paid   int64
		closed int
		after  account.Silk
	)
	err = txn.For(m.Store, m.Silk).Run(ctx, func(ctx context.Context) error {
		es, err := ls.OpenLottery(ctx)
		if err != nil {
			return err
		}
		e, pot, ok := mall.LotteryPick(es, roll)
		if !ok {
			return mall.ErrNoLotteryEntries
		}
		won, paid = e, pot
		if prize >= 0 {
			paid = prize
		}
		if paid > 0 {
			if after, err = m.Silk.AddSilk(ctx, e.AccountID, account.SilkOwn, paid); err != nil {
				return err
			}
		}
		closed, err = ls.CloseLottery(ctx, e.ID, paid, time.Now())
		return err
	})
	if err != nil {
		return "", 0, 0, err
	}
	name := fmt.Sprintf("character %d", won.CharacterID)
	if m.Chars != nil {
		if c, err := m.Chars.GetByID(ctx, won.CharacterID); err == nil && c != nil {
			name = c.Name
		}
	}
	if g.hub != nil {
		if e, ok := g.hub.EntityByCharacterID(won.CharacterID); ok && e.Session != nil {
			if paid > 0 {
				sendTo(e.Session, mall.OpSilk, mall.EncodeBalances(balancesOf(after)))
			}
			serviceLine(e.Session, fmt.Sprintf("You have won %d silk in the Silk Lottery!", paid))
		}
	}
	return name, paid, closed, nil
}
