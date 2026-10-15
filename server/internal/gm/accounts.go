package gm

// The account commands (round 788): /ban, retail's own GM command, and the
// OURS /block, /unblock and /blockinfo that put the operator console's
// punishments in the GM console. See docs/DEBUG_TOOLS.md.

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
)

// Sessions is the console's hold on live connections (the session layer's).
type Sessions interface {
	// KickCharacter ends the connection of the character named name if it
	// is in the world, and returns the name as the world holds it.
	KickCharacter(name string) (string, bool)
	// KickAccount ends accountID's connection, wherever it is (the world or
	// character select), and reports whether there was one.
	KickAccount(accountID int64) bool
}

// The /block limits (OURS).
const (
	// maxBlockDays bounds a timed block; longer is "forever".
	maxBlockDays = 3650
	// maxGuideBytes is the longest reason kept: what the gateway's 0x200-byte
	// reason field holds (session.maxBlockReasonBytes, READ 0x415f4c).
	maxGuideBytes = 0x200 - 1
	// defaultBlockGuide is the reason when the GM gives none.
	defaultBlockGuide = "Blocked by a game master."
	// maxBlockInfo is how many punishments /blockinfo lists, newest first.
	maxBlockInfo = 5
)

func (d *Deps) now() time.Time {
	if d.Now != nil {
		return d.Now()
	}
	return time.Now()
}

// ban is retail's Ban (READ: client command table 0x558937.., handler
// 0x5488b0, one argument -> 0x7010 {u16 0x000D, name}; SR_GameServer case
// 0x0D, 0x51f2c4..0x51f3e7): find the ONLINE character by name and force it
// out (FUN_004df050(player, 4)), log "BanPlayer: %s"; not found -> refused
// (0xB010 {2, 0x1404}). No database write: retail's Ban is a kick. So is
// this one -- the player may log straight back in; /block keeps an account
// out.
func (d *Deps) ban(args []string) Result {
	if len(args) != 1 {
		return refuse("usage: /ban <character> (a kick, as retail's Ban: nothing is stored; /block keeps an account out)")
	}
	if d.Sessions == nil {
		return refuse("no session control")
	}
	name, ok := d.Sessions.KickCharacter(args[0])
	if !ok {
		return refuse("no character named " + args[0] + " is in the world")
	}
	return Result{Text: "kicked " + name + " (retail's Ban is a kick: nothing is stored, they may log in again; /block keeps an account out)"}
}

// target is an account a command names, and how it was named.
type target struct {
	acc       *account.Account
	character string // the character it was named by, "" for @account
}

func (t target) String() string {
	if t.character != "" {
		return fmt.Sprintf("account %s (character %s)", t.acc.Username, t.character)
	}
	return "account " + t.acc.Username
}

// resolve finds the account a command names: "@name" is an account by its
// username (exact, as the store holds it), anything else a character by its
// name (without case), online or not.
func (d *Deps) resolve(ctx context.Context, name string) (target, string) {
	if d.AccountLookup == nil || d.Punishments == nil {
		return target{}, "no account store"
	}
	if user, ok := strings.CutPrefix(name, "@"); ok {
		if user == "" {
			return target{}, "name an account after @, e.g. @alice"
		}
		acc, err := d.AccountLookup.AccountByName(ctx, user)
		if errors.Is(err, account.ErrNoSuchAccount) {
			return target{}, "no account named " + user
		}
		if err != nil {
			return target{}, "could not look the account up: " + err.Error()
		}
		return target{acc: acc}, ""
	}
	owners, ok := d.Chars.(character.OwnerStore)
	if !ok {
		return target{}, "no character store to look " + name + " up in; name the account as @account"
	}
	c, err := owners.ByName(ctx, name)
	if errors.Is(err, character.ErrNotFound) {
		return target{}, "no character named " + name + " (name an account as @account)"
	}
	if err != nil {
		return target{}, "could not look the character up: " + err.Error()
	}
	acc, err := d.AccountLookup.AccountByID(ctx, c.AccountID)
	if err != nil {
		return target{}, "could not look " + c.Name + "'s account up: " + err.Error()
	}
	return target{acc: acc, character: c.Name}, ""
}

// parseBlockDuration reads 30m, 12h, 7d or forever (also infinite,
// permanent, perm): the length, and infinite for no end.
func parseBlockDuration(s string) (d time.Duration, infinite bool, ok bool) {
	switch strings.ToLower(s) {
	case "forever", "infinite", "permanent", "perm":
		return 0, true, true
	}
	if len(s) < 2 {
		return 0, false, false
	}
	n, err := strconv.Atoi(s[:len(s)-1])
	if err != nil || n <= 0 {
		return 0, false, false
	}
	var unit time.Duration
	switch s[len(s)-1] {
	case 'm', 'M':
		unit = time.Minute
	case 'h', 'H':
		unit = time.Hour
	case 'd', 'D':
		unit = 24 * time.Hour
	default:
		return 0, false, false
	}
	if n > maxBlockDays*int(24*time.Hour/unit) {
		return 0, false, false
	}
	return time.Duration(n) * unit, false, true
}

// restAfter is line with its first n fields and the space after them cut,
// the reason's words as typed.
func restAfter(line string, n int) string {
	rest := strings.TrimSpace(line)
	for i := 0; i < n; i++ {
		j := strings.IndexFunc(rest, isSpace)
		if j < 0 {
			return ""
		}
		rest = strings.TrimLeftFunc(rest[j:], isSpace)
	}
	return rest
}

func isSpace(r rune) bool { return r == ' ' || r == '\t' || r == '\n' || r == '\r' }

// cutGuide bounds a reason to maxGuideBytes at a character boundary.
func cutGuide(s string) string {
	if len(s) <= maxGuideBytes {
		return s
	}
	n := maxGuideBytes
	for n > 0 && !utf8.RuneStart(s[n]) {
		n--
	}
	return s[:n]
}

// whenText is a time as the console shows it: the server's local time.
func whenText(t time.Time) string { return t.Local().Format("2006-01-02 15:04") }

func untilText(p account.Punishment) string {
	if p.Infinite() {
		return "forever"
	}
	return "until " + whenText(p.EndAt)
}

// block puts a login block on an account (OURS: retail blocks from its
// operator console, the SMC's punishment plugin, never in game): a type-1
// punishment from now for the duration, the reason the player is shown,
// executor the GM's account; then the account's connection is ended, as
// the SMC's "Online User Ban" ends an online user's (READ GlobalManager
// 0x4463a2 -> 0x620D -> AgentServer 0x403d80). Refused for a GM's account
// (OURS safety rule) and for one already blocked (the SMC's "user already
// blocked", READ string SR_UserPunishment.dll 0x10077d90).
func (d *Deps) block(ctx context.Context, actor Actor, line string, args []string) Result {
	const usage = "usage: /block <character|@account> <30m|12h|7d|forever> [reason...]"
	if len(args) < 2 {
		return refuse(usage)
	}
	dur, infinite, ok := parseBlockDuration(args[1])
	if !ok {
		return refuse(usage + fmt.Sprintf(" (a number of m, h or d up to %dd, or forever)", maxBlockDays))
	}
	t, errText := d.resolve(ctx, args[0])
	if errText != "" {
		return refuse(errText)
	}
	if d.IsGMAccount != nil && d.IsGMAccount(t.acc.Username) {
		return refuse(t.String() + " is a GM account: a GM cannot block a GM (the operator removes it from -gm-accounts first)")
	}
	now := d.now()
	active, err := d.Punishments.ActivePunishments(ctx, t.acc.ID, now)
	if err != nil {
		return refuse("could not read the account's punishments: " + err.Error())
	}
	for _, p := range active {
		if p.Type.BlocksLogin() {
			return refuse(fmt.Sprintf("%s is already blocked %s (#%d); /unblock it first", t, untilText(p), p.Serial))
		}
	}
	guide := cutGuide(restAfter(line, 3))
	if guide == "" {
		guide = defaultBlockGuide
	}
	p := account.Punishment{
		AccountID: t.acc.ID, Type: account.PunishLogin, Executor: actor.Account, Guide: guide,
		Description: fmt.Sprintf("GM console: /block by %s as %s", actor.Account, actor.Name),
		BeginAt:     now,
	}
	if !infinite {
		p.EndAt = now.Add(dur)
	}
	p, err = d.Punishments.AddPunishment(ctx, p)
	if err != nil {
		return refuse("could not store the block: " + err.Error())
	}
	kicked := "not connected"
	if d.Sessions != nil && d.Sessions.KickAccount(t.acc.ID) {
		kicked = "disconnected"
	}
	return Result{Text: fmt.Sprintf("blocked %s %s (#%d, %s): %s", t, untilText(p), p.Serial, kicked, guide)}
}

// unblock ends an account's active login blocks (both login types), as the
// SMC's punishment update does. Nothing active: refused (the SMC's "[[NOT
// Blocked Currently]]", READ string 0x10077e4c).
func (d *Deps) unblock(ctx context.Context, args []string) Result {
	if len(args) != 1 {
		return refuse("usage: /unblock <character|@account>")
	}
	t, errText := d.resolve(ctx, args[0])
	if errText != "" {
		return refuse(errText)
	}
	n, err := d.Punishments.EndPunishments(ctx, t.acc.ID, d.now(), account.LoginBlockTypes...)
	if err != nil {
		return refuse("could not end the block: " + err.Error())
	}
	if n == 0 {
		return refuse(t.String() + " is not blocked")
	}
	return Result{Text: fmt.Sprintf("unblocked %s (%d block(s) ended)", t, n)}
}

// blockInfo lists an account's punishments, newest first, every type.
func (d *Deps) blockInfo(ctx context.Context, args []string) Result {
	if len(args) != 1 {
		return refuse("usage: /blockinfo <character|@account>")
	}
	t, errText := d.resolve(ctx, args[0])
	if errText != "" {
		return refuse(errText)
	}
	ps, err := d.Punishments.Punishments(ctx, t.acc.ID)
	if err != nil {
		return refuse("could not read the account's punishments: " + err.Error())
	}
	if len(ps) == 0 {
		return Result{Text: t.String() + ": no punishments"}
	}
	now := d.now()
	var b strings.Builder
	fmt.Fprintf(&b, "%s: %d punishment(s)", t, len(ps))
	if len(ps) > maxBlockInfo {
		fmt.Fprintf(&b, ", the newest %d", maxBlockInfo)
		ps = ps[:maxBlockInfo]
	}
	for _, p := range ps {
		state := "ended " + whenText(p.EndAt)
		switch {
		case p.ActiveAt(now):
			state = "ACTIVE " + untilText(p)
		case now.Before(p.BeginAt):
			state = "from " + whenText(p.BeginAt) + " " + untilText(p)
		}
		fmt.Fprintf(&b, "; #%d %s, %s, since %s, by %s: %s", p.Serial, p.Type, state, whenText(p.BeginAt), p.Executor, p.Guide)
	}
	return Result{Text: b.String()}
}
