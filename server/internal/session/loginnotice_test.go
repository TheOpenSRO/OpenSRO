package session

import "testing"

func TestParseLoginNotices(t *testing.T) {
	m := ParseLoginNotices(" Opensrogm = You lost the game ; bad ; =x; other=Hi")
	if len(m) != 2 || m["opensrogm"] != "You lost the game" || m["other"] != "Hi" {
		t.Fatalf("got %v", m)
	}
	if got := EncodeBigNotice("Hi"); len(got) != 4 || got[0] != 2 || got[1] != 0 || string(got[2:]) != "Hi" {
		t.Fatalf("encode %v", got)
	}
}
