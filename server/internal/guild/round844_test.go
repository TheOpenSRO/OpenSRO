package guild

import (
	"context"
	"errors"
	"strings"
	"testing"
)

var (
	_ ManageStore = (*MemStore)(nil)
	_ ManageStore = (*SQLStore)(nil)
)

type manageTestStore interface {
	Store
	ManageStore
}

// Round 844: the notice, the permission bits and the master's hand-over, on
// both stores.
func TestRound844ManageMem(t *testing.T) { testRound844Manage(t, NewMemStore()) }

func TestRound844ManageSQL(t *testing.T) { testRound844Manage(t, openTestSQLStore(t)) }

func testRound844Manage(t *testing.T, s manageTestStore) {
	t.Helper()
	ctx := context.Background()
	g, err := s.Create(ctx, "Notice844", 8441, "Boss")
	if err != nil {
		t.Fatal(err)
	}
	for i, n := range []string{"Ann", "Bob"} {
		if _, err := s.Join(ctx, g.ID, int64(8442+i), n); err != nil {
			t.Fatal(err)
		}
	}
	// The notice.
	g, err = s.SetNotice(ctx, g.ID, "Hello", "Line one\nLine two")
	if err != nil || g.NoticeTitle != "Hello" || g.NoticeBody != "Line one\nLine two" {
		t.Fatalf("notice: %+v %v", g, err)
	}
	if got, _ := s.Get(ctx, g.ID); got.NoticeTitle != "Hello" {
		t.Fatalf("notice not kept: %+v", got)
	}
	if _, err := s.SetNotice(ctx, 99999999, "a", "b"); !errors.Is(err, ErrGuildNotFound) {
		t.Fatalf("no guild: %v", err)
	}
	// The permissions: both rows at once, or neither.
	perm := func(g *Guild, id int64) Permission {
		for _, m := range g.Members {
			if m.CharacterID == id {
				return m.Permission
			}
		}
		t.Fatalf("no member %d", id)
		return 0
	}
	g, err = s.SetPermissions(ctx, g.ID, []PermissionChange{{8442, PermInvite | PermNotice}, {8443, PermExpel}})
	if err != nil || perm(g, 8442) != PermInvite|PermNotice || perm(g, 8443) != PermExpel {
		t.Fatalf("permissions: %+v %v", g, err)
	}
	if _, err := s.SetPermissions(ctx, g.ID, []PermissionChange{{8442, 0}, {8441, 0}}); !errors.Is(err, ErrIsMaster) {
		t.Fatalf("the master's row: %v", err)
	}
	if _, err := s.SetPermissions(ctx, g.ID, []PermissionChange{{8442, 0}, {77777, 0}}); !errors.Is(err, ErrNotInGuild) {
		t.Fatalf("a stranger's row: %v", err)
	}
	if got, _ := s.Get(ctx, g.ID); perm(got, 8442) != PermInvite|PermNotice {
		t.Fatalf("a refused batch changed a row: %+v", got)
	}
	// The hand-over.
	if _, err := s.TransferMaster(ctx, g.ID, 8441); !errors.Is(err, ErrIsMaster) {
		t.Fatalf("to the master: %v", err)
	}
	if _, err := s.TransferMaster(ctx, g.ID, 77777); !errors.Is(err, ErrNotInGuild) {
		t.Fatalf("to a stranger: %v", err)
	}
	g, err = s.TransferMaster(ctx, g.ID, 8443)
	if err != nil || g.LeaderID != 8443 {
		t.Fatalf("hand-over: %+v %v", g, err)
	}
	for _, m := range g.Members {
		switch m.CharacterID {
		case 8443:
			if m.Role != RoleLeader || m.Permission != PermAll || m.MemberClass() != 0 || m.SiegeAuthority != SiegeCommander {
				t.Fatalf("new master: %+v", m)
			}
		case 8441:
			if m.Role != RoleMember || m.Permission != MasterHandOverPermission || m.MemberClass() != 10 || m.SiegeAuthority != SiegeNone {
				t.Fatalf("old master: %+v", m)
			}
		}
	}
	// The old master can now be expelled; the new one cannot.
	if _, err := s.Remove(ctx, 8443); !errors.Is(err, ErrIsMaster) {
		t.Fatalf("new master removable: %v", err)
	}
	if _, err := s.Remove(ctx, 8441); err != nil {
		t.Fatalf("old master not removable: %v", err)
	}
	_, _ = s.Disband(ctx, g.ID)
}

func TestRound844CheckNotice(t *testing.T) {
	cases := []struct {
		title, body string
		want        error
	}{
		{"", "b", ErrNoticeTitle},
		{"t", "", ErrNoticeBody},
		{strings.Repeat("t", NoticeTitleMaxBytes), strings.Repeat("b", NoticeBodyMaxBytes), nil},
		{strings.Repeat("t", NoticeTitleMaxBytes+1), "b", ErrNoticeTitle},
		{"t", strings.Repeat("b", NoticeBodyMaxBytes+1), ErrNoticeBody},
		// Bytes, not characters: 43 three-byte runes are 129 bytes.
		{strings.Repeat("\uD55C", 43), "b", ErrNoticeTitle},
	}
	for _, c := range cases {
		if got := CheckNotice(c.title, c.body); got != c.want {
			t.Errorf("CheckNotice(%d, %d) = %v, want %v", len(c.title), len(c.body), got, c.want)
		}
	}
	if !NoticeQuoteRefused("it's") || !NoticeQuoteRefused(`say "hi"`) || NoticeQuoteRefused("plain") {
		t.Error("the quote filter")
	}
}
