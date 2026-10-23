package gm

// /avatar (round 789, OURS: a test tool, no retail counterpart): what the
// avatar slots hold, and a devil's spirit's expiry set by hand so its
// awakening, its wear and its expiry can be tested without waiting 28 days.
// The expiry lives where retail keeps it, the instance's Data word
// (OpenSRO's Durability; internal/avatar).

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/avatar"
)

const avatarUsage = "usage: /avatar (list the avatar slots) | /avatar spirit <bag slot> <seconds|0> (a devil's spirit in the bag: awake for that long, or 0 not awakened)"

func (d *Deps) avatar(ctx context.Context, actor Actor, args []string) Result {
	if len(args) == 0 {
		return d.avatarList(ctx, actor)
	}
	if len(args) != 3 || strings.ToLower(args[0]) != "spirit" {
		return refuse(avatarUsage)
	}
	slot, err := strconv.Atoi(args[1])
	if err != nil || slot < 0 {
		return refuse(avatarUsage)
	}
	secs, err := strconv.ParseInt(args[2], 10, 64)
	if err != nil || secs < 0 || secs > 0x7fffffff {
		return refuse(avatarUsage)
	}
	if d.Inv == nil || d.Items == nil {
		return refuse("no inventory or item table")
	}
	slots, err := d.Inv.List(ctx, actor.CharacterID)
	if err != nil {
		return refuse("reading the bag failed")
	}
	for _, sl := range slots {
		if sl.Index != slot {
			continue
		}
		it, err := d.Items.GetItem(ctx, sl.ItemID)
		if err != nil || !avatar.IsDevilSpirit(it) {
			return refuse(fmt.Sprintf("bag slot %d holds no devil's spirit", slot))
		}
		inst := sl.Instance()
		inst.Durability = 0
		if secs > 0 {
			inst.Durability = int(d.now().Unix() + secs)
		}
		if err := d.Inv.SetInstance(ctx, actor.CharacterID, slot, inst); err != nil {
			return refuse("setting the expiry failed: " + err.Error())
		}
		if secs == 0 {
			return Result{Text: fmt.Sprintf("devil's spirit in bag slot %d: not awakened", slot), RefreshInventory: true}
		}
		return Result{Text: fmt.Sprintf("devil's spirit in bag slot %d: awake for %ds", slot, secs), RefreshInventory: true}
	}
	return refuse(fmt.Sprintf("bag slot %d is empty", slot))
}

func (d *Deps) avatarList(ctx context.Context, actor Actor) Result {
	if d.Avatars == nil {
		return refuse("no avatar inventory on this server")
	}
	held, err := avatar.List(ctx, d.Avatars, d.Items, actor.CharacterID)
	if err != nil {
		return refuse("reading the avatar slots failed")
	}
	if len(held) == 0 {
		return Result{Text: "avatar slots: empty"}
	}
	now := d.now()
	var parts []string
	for _, h := range held {
		p := fmt.Sprintf("%d: item %d +%d, %d option(s)", h.Slot.Index, h.Slot.ItemID, h.Slot.OptLevel, len(h.Slot.MagParams))
		if avatar.IsDevilSpirit(h.Item) {
			switch {
			case h.Slot.Durability <= 0:
				p += ", not awakened"
			case avatar.Awake(h.Slot.Durability, now):
				p += fmt.Sprintf(", awake %s more", time.Unix(int64(h.Slot.Durability), 0).Sub(now).Round(time.Second))
			default:
				p += ", expired"
			}
		}
		parts = append(parts, p)
	}
	return Result{Text: "avatar slots: " + strings.Join(parts, "; ")}
}
