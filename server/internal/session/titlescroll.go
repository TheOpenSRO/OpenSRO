package session

// The title scrolls and the Random Wing Scroll (round 838). Both are the
// private server's own rows (a Pandora/vPlus archive): ITEM_TITLE_1 ..
// ITEM_TITLE_255 (TypeID 3/3/13/14, "<name> Title", no Param block) and
// ITEM_RANDOM_WING (3/3/13/1). What they did was that server's filter, which
// no binary here holds, so what they do is OURS, built to their in-game text;
// how a title is carried and drawn is the original's (READ).
//
// THE TITLE IS RETAIL'S HWAN LEVEL (READ).
//   - The server: _CHAR.HwanLevel (charData +0xf2) is the byte. CGObjChar::
//     UpdateHwanLevel (0x004a9f40) stores it on the object (+0x1c58), and
//     GObjPC::FUN_004a9e20 asserts it is within the hwan level table, writes
//     it to the character row (dirty bit 0x2000) and FUN_004a9f70 sends
//     0x30DF {u32 object id, u8 level} to the object's view.
//   - The client: 0x30DF (FUN_008a7630) finds the object and calls
//     FUN_009ca930(level); the spawn record's HwanLevel (pc_spawn row 3,
//     slot 22 -> DAT_00ef1bb8) reaches the same function from slot 27
//     (0x9dbcc0), and 0x3013 reads it too. FUN_009ca930 stores the level
//     (+0x764) and builds the title through FUN_00941000: hwanleveldata.txt's
//     row for the level, its Title_CH70 or Title_EU70 key by the body's race,
//     the text table's line for the key ("" on a miss) -- then hands it to the
//     title slot (vslot 30, c:0x9c28a0), the line drawn left of the name in
//     #FFE65B and emptied while a job suit is worn.
//   - The archive (MEASURED): hwanleveldata.txt has rows 0..255, row N naming
//     UIO_SECOND_HWAN_CH_NAME_LEVEL_N in both columns, and textuisystem's first
//     row for each key is the private server's title ("Ambassador" for 1, "SRO
//     Lover" for 196, "Custom" for 255); ITEM_TITLE_N's name is that title +
//     " Title" for every N with a name. So ITEM_TITLE_N gives hwan level N.
//
// OURS, the use:
//   - The scroll gives its title and is spent. A character holds one title,
//     so a new one REPLACES the old -- the custom scroll's own text says as
//     much ("If you decide to use a different custom title, the old one will
//     be lost!"). The same title again is refused and the scroll kept.
//   - ITEM_TITLE_255, the "Custom Title Scroll": "1-Click on the scroll 2-A
//     window will open where you can enter your custom title". The client
//     opens the box on the scroll's right-click and sends the text in the use
//     request (UseOptionCustomTitle); a use without it is refused and the
//     scroll kept. The text is checked by customTitleOf, stored beside level
//     255, and sent to everyone who sees the character as OpCustomTitle.
//   - Our server has no 0x3013, so the character's own title reaches it as a
//     0x30DF right after the world entry (titleAfterEnter).
//
// OURS, the Random Wing Scroll: "A scroll that will grant you a random wing
// effect in your Item Chest upon usage. Success ratio is 100%". Its row's
// Desc128_1 names SKILL_CELESTIUS_SILK_SCROLL_10, a placeholder buff (cbuf,
// dura 1000 ms, no effect; MEASURED) that the skill item path would have
// cast; it is claimed here, ahead of that path. One wing visual scroll,
// picked evenly from randomWingPool, goes to the item chest (round 837), as
// the starter packages' contents do.
//
// The messages:
//
//	S->C 0x30DF {u32 uid, u8 level}   retail's hwan level update (READ)
//	S->C 0x01A8 {u32 uid, str text}   OURS: a character's custom title text
//
// and the use request's option UseOptionCustomTitle {u16 length, UTF-8}.

import (
	"context"
	"encoding/binary"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
	"sync"
	"unicode/utf8"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mall"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
)

const (
	// OpHwanLevel is retail's 0x30DF (READ, see the file comment).
	OpHwanLevel uint16 = 0x30DF
	// OpCustomTitle is a character's custom title text (OURS; 0x01A8 was free
	// in internal/session, internal/proto and the client's net/).
	OpCustomTitle uint16 = 0x01A8
	// UseOptionCustomTitle marks a use request that carries the custom
	// title's text after the option byte (OURS).
	UseOptionCustomTitle byte = 0xC7
)

// titleScrollPrefix names the title scrolls: ITEM_TITLE_<level>.
const titleScrollPrefix = "ITEM_TITLE_"

// randomWingCode is the Random Wing Scroll's code name.
const randomWingCode = "ITEM_RANDOM_WING"

// titleScrollOf reports the title scroll or the Random Wing Scroll by code
// name (upper case). ITEM_TITLE_COLOR_* is not a title scroll: its suffix is
// no number.
func titleScrollOf(code string) (serviceScroll, bool) {
	if code == randomWingCode {
		return serviceScroll{kind: svcRandomWing}, true
	}
	n, ok := strings.CutPrefix(code, titleScrollPrefix)
	if !ok {
		return serviceScroll{}, false
	}
	level, err := strconv.Atoi(n)
	if err != nil || level < 1 || level > 255 {
		return serviceScroll{}, false
	}
	return serviceScroll{kind: svcTitle, amount: int64(level)}, true
}

// customTitleMax is the custom title's longest text, in characters (OURS:
// the archive's longest title, "Pleveling Expert #1", is 19).
const customTitleMax = 20

// customTitlePunct is what a custom title may hold besides ASCII letters,
// digits and single spaces (OURS: plain ASCII, which every plate font
// draws; nothing that reads as markup or as the job alias's "*").
const customTitlePunct = "-_.'!#&+?:()"

// The custom title's refusals (OURS).
const (
	customTitleNone  = "Enter your custom title in the window that opens when you right-click the scroll."
	customTitleEmpty = "Enter a title."
	customTitleLong  = "That title is too long."
	customTitleChars = "A title may hold only letters, digits, single spaces and - _ . ' ! # & + ? : ( )"
)

// customTitleOf is the text a custom title is stored as -- trimmed -- or the
// refusal when it is empty, too long or holds anything customTitlePunct and
// the letters, digits and single spaces do not.
func customTitleOf(text string) (string, string) {
	text = strings.TrimSpace(text)
	if text == "" {
		return "", customTitleEmpty
	}
	if !utf8.ValidString(text) || utf8.RuneCountInString(text) > customTitleMax {
		return "", customTitleLong
	}
	prevSpace := false
	for _, r := range text {
		switch {
		case r == ' ':
			if prevSpace {
				return "", customTitleChars
			}
			prevSpace = true
			continue
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
		case r < 0x80 && strings.ContainsRune(customTitlePunct, r):
		default:
			return "", customTitleChars
		}
		prevSpace = false
	}
	return text, ""
}

// title is a title scroll's use: level stored (with the custom text for
// CustomTitleLevel), the scroll spent in the same transaction, then 0x30DF
// (and the custom text first) to everyone who sees the character.
func (u serviceUse) title(ctx context.Context, level uint8, text string) error {
	st, ok := u.d.Chars.(character.TitleStore)
	if !ok {
		return u.fail("that cannot be used here")
	}
	custom := ""
	if level == character.CustomTitleLevel {
		if text == "" {
			return u.fail(customTitleNone)
		}
		var why string
		if custom, why = customTitleOf(text); why != "" {
			return u.fail(why)
		}
	}
	cur, curText, err := st.Title(ctx, u.cid)
	if err != nil {
		return u.fail("lookup failed")
	}
	if cur == level && curText == custom {
		return u.fail("You already have that title.")
	}
	if ok, err := u.run(ctx, func(ctx context.Context) error {
		return st.SetTitle(ctx, u.cid, level, custom)
	}, u.d.Chars); !ok {
		return err
	}
	noteTitle(u.cid, level, custom)
	line := "Your title has been changed."
	if custom != "" {
		line = fmt.Sprintf("Your title is now %q.", custom)
	}
	if err := u.accepted(line); err != nil {
		return err
	}
	if u.d.Hub == nil {
		sendTitle(u.sess, u.cid, level, custom)
		return nil
	}
	to := equipObservers(u.d.Hub, u.cid)
	if custom != "" {
		sendAboutOwner(to, u.cid, OpCustomTitle, encodeCustomTitle(u.cid, custom))
	}
	sendAboutOwner(to, u.cid, OpHwanLevel, encodeHwanLevel(u.cid, level))
	return nil
}

// randomWingPool is the Random Wing Scroll's wings (OURS, MEASURED in the
// player's archive): every VSROEDITORCOM visual named a wing whose USU1 casts
// its own number's skill -- 09, 10 and 12 ("Wings of Conflagration / the
// Ghostly / Azure"), 17..23 ("Holy Wings of ...") and 24..33 ("Graceful Wings
// (Type A..J)"); the twenty the mall's Wings tab sells. VISUAL_11 ("Wings of
// Blood") is left out: its row's USU1 names SKILL_VSROEDITORCOM_VISUAL_01,
// the Horns of Conflagration, and the mall does not sell it. The Godbless
// wings (3/3/13/1, a skill item each) are not "wing visual scrolls" and are
// left out too.
var randomWingPool = func() []string {
	var out []string
	for _, n := range []int{9, 10, 12, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33} {
		out = append(out, fmt.Sprintf("ITEM_VSROEDITORCOM_VISUAL_%02d", n))
	}
	return out
}()

// randomWingFrom is the chest's "from" text for the wing (OURS).
const randomWingFrom = "Random Wing Scroll"

// randomWing is the Random Wing Scroll: one wing of the pool, evenly, into
// the item chest; the scroll spent in the same transaction. The pool is
// what of it the item table holds; none refuses the scroll.
func (u serviceUse) randomWing(ctx context.Context) error {
	m := mallRT.Load()
	byCode, ok := u.d.Items.(itemByCode)
	if m == nil || m.Store == nil || !ok {
		return u.fail("the item chest is not available here")
	}
	var pool []*refdata.Item
	for _, code := range randomWingPool {
		if ref, err := byCode.GetItemByCode(ctx, code); err == nil && ref != nil {
			pool = append(pool, ref)
		}
	}
	if len(pool) == 0 {
		return u.fail("This scroll cannot be opened on this server.")
	}
	pick := pool[u.d.roll(int64(len(pool)))]
	e := mall.ChestEntry{Owner: u.cid, ItemID: pick.ID, Quantity: 1, From: randomWingFrom, At: u.d.now()}
	if ok, err := u.run(ctx, func(ctx context.Context) error {
		id, err := m.Store.AddToChest(ctx, e)
		e.ID = id
		return err
	}, m.Store); !ok {
		return err
	}
	if err := u.accepted("A random wing has been placed in your Item Chest."); err != nil {
		return err
	}
	u.d.logger().Info("random wing", "character_id", u.cid, "wing", pick.CodeName)
	sendTo(u.sess, mall.OpChestReceived, mall.EncodeChestReceived(e.ItemID, e.Quantity))
	return nil
}

// --- the title on the wire -------------------------------------------------------

// titleEntry is one character's cached title.
type titleEntry struct {
	level  uint8
	custom string
}

// titles caches each character's title (int64 -> titleEntry), filled at
// world entry and on a change, so a spawn record never reads the store.
var titles sync.Map

// noteTitle caches a character's title.
func noteTitle(characterID int64, level uint8, custom string) {
	if level == 0 {
		titles.Delete(characterID)
		return
	}
	titles.Store(characterID, titleEntry{level: level, custom: custom})
}

// hwanLevelOf is the spawn record's HwanLevel for characterID.
func hwanLevelOf(characterID int64) uint8 {
	if v, ok := titles.Load(characterID); ok {
		return v.(titleEntry).level
	}
	return 0
}

func encodeHwanLevel(characterID int64, level uint8) []byte {
	return append(binary.LittleEndian.AppendUint32(nil, uint32(characterID)), level)
}

func encodeCustomTitle(characterID int64, text string) []byte {
	return appendServiceStr(binary.LittleEndian.AppendUint32(nil, uint32(characterID)), text)
}

// customTitleFrame is characterID's OpCustomTitle for its spawn, nil
// without a custom title.
func customTitleFrame(characterID int64) *gateway.Frame {
	v, ok := titles.Load(characterID)
	if !ok || v.(titleEntry).custom == "" {
		return nil
	}
	return gateway.MustFrame(&proto.Packet{Opcode: OpCustomTitle, Data: encodeCustomTitle(characterID, v.(titleEntry).custom)})
}

// sendTitle tells sess characterID's title: the custom text first, so the
// level's redraw has it.
func sendTitle(sess *gateway.Session, characterID int64, level uint8, custom string) {
	if custom != "" {
		sendTo(sess, OpCustomTitle, encodeCustomTitle(characterID, custom))
	}
	sendTo(sess, OpHwanLevel, encodeHwanLevel(characterID, level))
}

// titleAtEntry caches characterID's title at the top of the world entry
// (enterOwned), before the character is placed.
func titleAtEntry(ctx context.Context, chars character.Store, characterID int64) {
	st, ok := chars.(character.TitleStore)
	if !ok {
		return
	}
	level, custom, err := st.Title(ctx, characterID)
	if err != nil {
		slog.Warn("title: reading at entry failed", "character_id", characterID, "err", err)
		return
	}
	noteTitle(characterID, level, custom)
}

// titleAfterEnter tells the arrival its own title after OpSelfID -- what
// retail's 0x3013 carries (OURS: as a 0x30DF). Nothing for none: the client
// forgets its own title at every world entry (TitleNet).
func titleAfterEnter(sess *gateway.Session, characterID int64) {
	if v, ok := titles.Load(characterID); ok {
		t := v.(titleEntry)
		sendTitle(sess, characterID, t.level, t.custom)
	}
}
