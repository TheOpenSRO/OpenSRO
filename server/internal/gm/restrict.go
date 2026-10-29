package gm

// Round 840, lane B: the chat and trade bans in the GM console, beside
// round 788's /block (accounts.go), and the quest block's test tool.
//
// Retail sets both bans from the operator console (the SMC's punishment
// plugin: "block p2p trade" 3, "block chat" 4), never in game; the account
// side then tells the game server, which keeps them in the player's two
// restriction slots (session/restriction.go). OURS, as /block is: /chatban,
// /tradeban, /unchatban and /untradeban store and end the same punishment
// records (account.PunishChat / PunishTrade, account_punishments) and drop
// the session layer's cached slots so the next chat line or trade sees them.
// Unlike /block they are not refused for a GM's account: /block's rule
// guards against a GM locking a GM out, and neither ban locks anyone out.

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
)

// RestrictionControl is the session layer's hold on the restriction slots
// and the quest block (round 840).
type RestrictionControl interface {
	// RestrictionsChanged drops accountID's cached chat and trade bans, so
	// the next check reads the store.
	RestrictionsChanged(accountID int64)
	// QuestBlock ORs mask into (clear: releases mask from) the quest block
	// of the in-world character named name; it returns the block after, and
	// the name as the world holds it.
	QuestBlock(name string, mask uint32, clear bool) (block uint32, who string, ok bool)
}

// banKind is one of the two bans the console sets.
type banKind struct {
	typ   account.PunishmentType
	cmd   string // the set command, without the slash
	what  string // "chat-banned" / "trade-banned"
	guide string // the default reason
}

var (
	chatBan  = banKind{typ: account.PunishChat, cmd: "chatban", what: "chat-banned", guide: "Chat restricted by a game master."}
	tradeBan = banKind{typ: account.PunishTrade, cmd: "tradeban", what: "trade-banned", guide: "Trading restricted by a game master."}
)

// restrict puts a chat or trade ban on an account: a punishment of k's type
// from now for the duration, the reason, executor the GM's account. Refused
// for an account already under that ban (the SMC's "user already blocked").
func (d *Deps) restrict(ctx context.Context, actor Actor, line string, args []string, k banKind) Result {
	usage := fmt.Sprintf("usage: /%s <character|@account> <30m|12h|7d|forever> [reason...]", k.cmd)
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
	now := d.now()
	active, err := d.Punishments.ActivePunishments(ctx, t.acc.ID, now)
	if err != nil {
		return refuse("could not read the account's punishments: " + err.Error())
	}
	for _, p := range active {
		if p.Type == k.typ {
			return refuse(fmt.Sprintf("%s is already %s %s (#%d); /un%s it first", t, k.what, untilText(p), p.Serial, k.cmd))
		}
	}
	guide := cutGuide(restAfter(line, 3))
	if guide == "" {
		guide = k.guide
	}
	p := account.Punishment{
		AccountID: t.acc.ID, Type: k.typ, Executor: actor.Account, Guide: guide,
		Description: fmt.Sprintf("GM console: /%s by %s as %s", k.cmd, actor.Account, actor.Name),
		BeginAt:     now,
	}
	if !infinite {
		p.EndAt = now.Add(dur)
	}
	p, err = d.Punishments.AddPunishment(ctx, p)
	if err != nil {
		return refuse("could not store the ban: " + err.Error())
	}
	if d.Restrictions != nil {
		d.Restrictions.RestrictionsChanged(t.acc.ID)
	}
	return Result{Text: fmt.Sprintf("%s %s %s (#%d): %s", k.what, t, untilText(p), p.Serial, guide)}
}

// unrestrict ends an account's active bans of k's type. Nothing active:
// refused (the SMC's "[[NOT Blocked Currently]]").
func (d *Deps) unrestrict(ctx context.Context, args []string, k banKind) Result {
	if len(args) != 1 {
		return refuse(fmt.Sprintf("usage: /un%s <character|@account>", k.cmd))
	}
	t, errText := d.resolve(ctx, args[0])
	if errText != "" {
		return refuse(errText)
	}
	n, err := d.Punishments.EndPunishments(ctx, t.acc.ID, d.now(), k.typ)
	if err != nil {
		return refuse("could not end the ban: " + err.Error())
	}
	if d.Restrictions != nil {
		d.Restrictions.RestrictionsChanged(t.acc.ID)
	}
	if n == 0 {
		return refuse(fmt.Sprintf("%s is not %s", t, k.what))
	}
	return Result{Text: fmt.Sprintf("%s is no longer %s (%d ended)", t, k.what, n)}
}

// questBlock sets or clears an in-world character's quest block (OURS, a
// test tool: retail's quests set it, and none sets the stall's 0x200 --
// session/restriction.go). /questblock <character> <mask>|clear [mask].
func (d *Deps) questBlock(args []string) Result {
	const usage = "usage: /questblock <character> <mask, e.g. 0x200 (the stall)> | /questblock <character> clear [mask]"
	if d.Restrictions == nil {
		return refuse("no quest block control")
	}
	if len(args) < 2 || len(args) > 3 {
		return refuse(usage)
	}
	clear := strings.EqualFold(args[1], "clear")
	maskText := args[1]
	if clear {
		maskText = "0xffffffff"
		if len(args) == 3 {
			maskText = args[2]
		}
	} else if len(args) != 2 {
		return refuse(usage)
	}
	mask, err := strconv.ParseUint(maskText, 0, 32)
	if err != nil || mask == 0 {
		return refuse(usage)
	}
	block, who, ok := d.Restrictions.QuestBlock(args[0], uint32(mask), clear)
	if !ok {
		return refuse("no character named " + args[0] + " is in the world")
	}
	verb := "set"
	if clear {
		verb = "released"
	}
	return Result{Text: fmt.Sprintf("%s 0x%x on %s's quest block: now 0x%x", verb, mask, who, block)}
}
