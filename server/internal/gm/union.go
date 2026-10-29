package gm

import (
	"context"
	"strings"
)

// UnionControl is /union's hook (round 842, OURS: a test tool -- OpenSRO
// has none of the original's union request flow yet). The session layer
// fills it in.
type UnionControl interface {
	// Join puts characterID's guild into the union of the guild named host,
	// forming one when that guild has none, and tells everyone.
	Join(ctx context.Context, characterID int64, host string) (string, error)
	// Leave takes characterID's guild out of its union, or, with expel
	// non-empty, that guild out of characterID's union, and tells everyone.
	Leave(ctx context.Context, characterID int64, expel string) (string, error)
}

const unionUsage = "usage: /union <guild> | /union leave | /union expel <guild>"

// union is /union <guild> (join that guild's union), /union leave and
// /union expel <guild>.
func (d *Deps) union(ctx context.Context, actor Actor, args []string) Result {
	if d.Unions == nil {
		return refuse("no union store")
	}
	if len(args) == 0 {
		return refuse(unionUsage)
	}
	var text string
	var err error
	switch strings.ToLower(args[0]) {
	case "leave":
		if len(args) != 1 {
			return refuse(unionUsage)
		}
		text, err = d.Unions.Leave(ctx, actor.CharacterID, "")
	case "expel":
		if len(args) != 2 {
			return refuse(unionUsage)
		}
		text, err = d.Unions.Leave(ctx, actor.CharacterID, args[1])
	default:
		if len(args) != 1 {
			return refuse(unionUsage)
		}
		text, err = d.Unions.Join(ctx, actor.CharacterID, args[0])
	}
	if err != nil {
		return refuse(err.Error())
	}
	return Result{Text: text}
}
