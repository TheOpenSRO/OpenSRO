package jobs

import (
	"context"
	"math"
	"sort"
)

// RankingSize is the weekly tables' TOP 50 (READ _UpdateTriangleJobWeekly).
const RankingSize = 50

// Weekly is _UpdateTriangleJobWeekly (READ, the shard's procedure; who runs it
// in retail is not the GameServer -- no reference in it -- so INFERRED a SQL
// Agent job; OpenSRO runs it on its own clock, cmd/server's -job-week).
// In order:
//
//  1. Each reward pool (2 robbers, 3 hunters) is shared out by contribution:
//     Reward += pool x Contribution / SUM(Contribution) (64-bit, integer
//     division), capped at INT_MAX, and the pool set to 0. Retail skips a
//     kind whose total contribution and pool are both 0; OURS: a kind whose
//     total contribution is 0 keeps its pool (retail's division would fail).
//  2. The activity tables: each kind's TOP 50 by Level, then Exp, with the
//     alias, level, exp and the body's country.
//  3. The contribution tables, only for a kind where someone has
//     Contribution > 0: its TOP 50 by Contribution with the alias, level and
//     contribution; then every contribution of that kind is set to 0.
//
// Ties: the procedure's ORDER BY leaves them to the engine; OURS breaks them
// by character id.
func Weekly(ctx context.Context, st Store, country func(charID int64) uint8) error {
	for _, k := range []Kind{KindThief, KindHunter} {
		recs, err := st.List(ctx, k)
		if err != nil {
			return err
		}
		var total int64
		for _, r := range recs {
			total += r.Contribution
		}
		if total == 0 {
			continue
		}
		pool, err := st.TakePool(ctx, k)
		if err != nil {
			return err
		}
		for _, r := range recs {
			reward := r.Reward + pool*r.Contribution/total
			if reward > math.MaxInt32 {
				reward = math.MaxInt32
			}
			if reward != r.Reward {
				r.Reward = reward
				if err := st.Save(ctx, r); err != nil {
					return err
				}
			}
		}
	}
	for _, k := range []Kind{KindTrader, KindThief, KindHunter} {
		recs, err := st.List(ctx, k)
		if err != nil {
			return err
		}
		act := append([]Record(nil), recs...)
		sort.SliceStable(act, func(i, j int) bool {
			if act[i].Level != act[j].Level {
				return act[i].Level > act[j].Level
			}
			if act[i].Exp != act[j].Exp {
				return act[i].Exp > act[j].Exp
			}
			return act[i].CharID < act[j].CharID
		})
		var rows []RankRow
		for i, r := range act {
			if i == RankingSize {
				break
			}
			c := uint8(0)
			if country != nil {
				c = country(r.CharID)
			}
			rows = append(rows, RankRow{Rank: i + 1, Alias: r.Alias, Level: r.Level, Exp: r.Exp, Country: c})
		}
		if err := st.SetRankings(ctx, k, RankActivity, rows); err != nil {
			return err
		}
		any := false
		for _, r := range recs {
			any = any || r.Contribution > 0
		}
		if !any {
			continue
		}
		con := append([]Record(nil), recs...)
		sort.SliceStable(con, func(i, j int) bool {
			if con[i].Contribution != con[j].Contribution {
				return con[i].Contribution > con[j].Contribution
			}
			return con[i].CharID < con[j].CharID
		})
		rows = nil
		for i, r := range con {
			if i == RankingSize {
				break
			}
			rows = append(rows, RankRow{Rank: i + 1, Alias: r.Alias, Level: r.Level, Contribution: r.Contribution})
		}
		if err := st.SetRankings(ctx, k, RankContribution, rows); err != nil {
			return err
		}
		for _, r := range recs {
			if r.Contribution != 0 {
				r.Contribution = 0
				if err := st.Save(ctx, r); err != nil {
					return err
				}
			}
		}
	}
	return nil
}
