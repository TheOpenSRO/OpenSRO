package gm

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
)

// Round 844 lane G part 2: two test tools for the guild's master-release vote
// and the GP-bought guild goods (OURS, like /guildlevel; the original has no
// such commands).

// guildAbsent sets a member of the GM's own guild as last logged out that
// many days ago (/guildabsent <member> <days>): the vote needs its master
// away 45 days, which a live test cannot wait for.
func (d *Deps) guildAbsent(ctx context.Context, actor Actor, args []string) Result {
	const usage = "usage: /guildabsent <member> <days>"
	if len(args) != 2 {
		return refuse(usage)
	}
	days, err := strconv.Atoi(args[1])
	if err != nil || days < 0 {
		return refuse(usage)
	}
	ps, ok := d.Guilds.(guild.PresenceStore)
	if d.Guilds == nil || !ok {
		return refuse("no guild store")
	}
	g, err := d.Guilds.GetByCharacter(ctx, actor.CharacterID)
	if err != nil {
		return refuse("you are not in a guild")
	}
	for _, m := range g.Members {
		if strings.EqualFold(m.Name, args[0]) {
			now := time.Now
			if d.Now != nil {
				now = d.Now
			}
			if err := ps.SetLastLogout(ctx, m.CharacterID, now().AddDate(0, 0, -days)); err != nil {
				return refuse("setting the logout failed: " + err.Error())
			}
			return Result{Text: fmt.Sprintf("%s last logged out %d day(s) ago", m.Name, days)}
		}
	}
	return refuse(args[0] + " is not in your guild")
}

// guildGP credits the GM's own guild n guild points (/guildgp <n>), counted
// as the GM's donation.
func (d *Deps) guildGP(ctx context.Context, actor Actor, args []string) Result {
	if len(args) != 1 {
		return refuse("usage: /guildgp <n>")
	}
	n, err := strconv.Atoi(args[0])
	if err != nil || n <= 0 {
		return refuse("usage: /guildgp <n>")
	}
	if d.Guilds == nil {
		return refuse("no guild store")
	}
	g, err := d.Guilds.GetByCharacter(ctx, actor.CharacterID)
	if err != nil {
		return refuse("you are not in a guild")
	}
	if err := d.Guilds.AddPoints(ctx, g.ID, actor.CharacterID, n); err != nil {
		return refuse("crediting guild points failed: " + err.Error())
	}
	return Result{Text: fmt.Sprintf("%s has %d more guild points", g.Name, n)}
}
