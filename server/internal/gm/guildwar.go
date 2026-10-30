package gm

import (
	"context"
	"strconv"
	"strings"
)

// GuildWarControl is /guildwar's hook (round 844, lane V, OURS: a QA aid --
// the original has no such command; wars are declared through the guild
// window). The session layer fills GuildWars in.
type GuildWarControl interface {
	// List is characterID's guild's wars.
	List(ctx context.Context, characterID int64) (string, error)
	// End moves the war between characterID's guild and the guild named
	// enemy to end in seconds.
	End(ctx context.Context, characterID int64, enemy string, seconds int) (string, error)
}

// GuildWars is what /guildwar drives; nil refuses it.
var GuildWars GuildWarControl

const guildWarUsage = "usage: /guildwar | /guildwar end <guild> [seconds]"

// guildWar is /guildwar (the list) and /guildwar end <guild> [seconds].
func (d *Deps) guildWar(ctx context.Context, actor Actor, args []string) Result {
	if GuildWars == nil {
		return refuse("no war store")
	}
	var text string
	var err error
	switch {
	case len(args) == 0:
		text, err = GuildWars.List(ctx, actor.CharacterID)
	case strings.ToLower(args[0]) == "end" && (len(args) == 2 || len(args) == 3):
		secs := 0
		if len(args) == 3 {
			n, perr := strconv.Atoi(args[2])
			if perr != nil || n < 0 {
				return refuse(guildWarUsage)
			}
			secs = n
		}
		text, err = GuildWars.End(ctx, actor.CharacterID, args[1], secs)
	default:
		return refuse(guildWarUsage)
	}
	if err != nil {
		return refuse(err.Error())
	}
	return Result{Text: text}
}
