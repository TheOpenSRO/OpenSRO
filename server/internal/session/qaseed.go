package session

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/skilljob"
	"github.com/TheOpenSRO/OpenSRO/server/internal/timedjob"
)

// SeedQAJobs (round 864 follow-up, OURS, a QA tool) puts rows into an
// in-memory server's timed-job store and item skill-job store before it
// serves, so a lane server can stand in for a character's kept state (a
// premium used weeks ago). One row a line, '#' comments:
//
//	timed,<char>,<type>,<sub>,<ref>,<key>,<started RFC3339>,<ends RFC3339 or empty>,<v1>,<v2>,<v3>,<v4>
//	skill,<char>,<skill>,<item>,<until RFC3339>
func SeedQAJobs(ctx context.Context, path string, timed timedjob.Store) (int, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	n := 0
	sc := bufio.NewScanner(f)
	for line := 1; sc.Scan(); line++ {
		text := strings.TrimSpace(sc.Text())
		if text == "" || strings.HasPrefix(text, "#") {
			continue
		}
		c := strings.Split(text, ",")
		for i := range c {
			c[i] = strings.TrimSpace(c[i])
		}
		bad := func(err error) (int, error) { return n, fmt.Errorf("qa seed %s:%d: %w", path, line, err) }
		num := func(s string) int64 {
			v, e := strconv.ParseInt(s, 10, 64)
			if e != nil && err == nil {
				err = e
			}
			return v
		}
		at := func(s string) time.Time {
			if s == "" {
				return time.Time{}
			}
			t, e := time.Parse(time.RFC3339Nano, s)
			if e != nil && err == nil {
				err = e
			}
			return t
		}
		switch {
		case c[0] == "timed" && len(c) == 12:
			j := timedjob.Job{CharID: num(c[1]), Type: int(num(c[2])), Sub: c[3], Ref: num(c[4]), Key: num(c[5]),
				Start: at(c[6]), End: at(c[7]), V1: num(c[8]), V2: num(c[9]), V3: num(c[10]), V4: num(c[11])}
			if err != nil {
				return bad(err)
			}
			if err := timed.Put(ctx, j); err != nil {
				return bad(err)
			}
		case c[0] == "skill" && len(c) == 5:
			j := skilljob.Job{CharacterID: num(c[1]), SkillID: num(c[2]), ItemID: num(c[3]), Until: at(c[4])}
			if err != nil {
				return bad(err)
			}
			if err := jobStore().Put(ctx, j); err != nil {
				return bad(err)
			}
		default:
			return bad(fmt.Errorf("want timed,<12 fields> or skill,<5 fields>: %q", text))
		}
		n++
	}
	return n, sc.Err()
}
