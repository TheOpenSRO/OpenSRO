package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/avatar"
)

// Round 839: -mode itemoptlevel over made-up rows in both sources' layouts.
// Item 501 has option rows at +0 and +1; its sibling 502 has the same rows
// at +0 and none at +1 (it gets 501's +1 as "optinf"); 503's +0 differs
// from 501's, so its empty +1 stays empty; 504's +0 is shared by two
// siblings (505 and 507) whose +1 rows disagree, so nothing is inferred for
// it.
func TestExportItemOptLevel839(t *testing.T) {
	dir := t.TempDir()
	write := func(name, body string) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		return p
	}
	// The shard DB's three tables, with their own column names.
	ability := write("_RefAbilityByItemOptLevel.csv", "Service,ID,RefItemID,ItemOptLevel\n"+
		"1,1,501,0\n1,2,501,1\n1,3,502,0\n1,4,502,1\n1,5,503,0\n1,6,503,1\n1,7,504,0\n1,8,504,1\n1,9,505,0\n1,10,505,1\n0,11,506,0\n"+
		"1,12,507,0\n1,13,507,1\n")
	opts := write("_RefMagicOptByItemOptLevel.csv", "Link,RefMagicOptID,MagicOptValue,TooltipType,TooltipCodename\n"+
		"1,10,5,0,xxx\n1,11,5,0,xxx\n2,10,6,0,xxx\n2,11,6,0,xxx\n2,12,1,1,xxx\n"+
		"3,11,5,0,xxx\n3,10,5,0,xxx\n"+ // 502 +0: 501's +0 in another order
		"5,10,9,0,xxx\n"+ // 503 +0: not 501's
		"7,13,1,0,xxx\n"+ // 504 +0 ...
		"9,13,1,0,xxx\n10,10,7,0,xxx\n"+ // ... is 505's ...
		"12,13,1,0,xxx\n13,10,8,0,xxx\n") // ... and 507's, whose +1 differ
	skills := write("_RefSkillByItemOptLevel.csv", "Link,RefSkillID\n2,900\n4,900\n11,901\n")
	out := filepath.Join(dir, "iol.csv")
	if err := exportItemOptLevel(out, []string{ability, opts, skills}); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	got := string(raw)
	for _, want := range []string{
		"502,1,optinf,10,6\n502,1,optinf,11,6\n502,1,optinf,12,1\n502,1,skill,900,0\n",
		"501,1,opt,10,6\n",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("export lacks %q:\n%s", want, got)
		}
	}
	for _, not := range []string{"503,1,", "504,1,", "506,", "901"} {
		if strings.Contains(got, not) {
			t.Errorf("export has %q:\n%s", not, got)
		}
	}

	// The server's reader keeps the inferred rows apart.
	f, err := os.Open(out)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	tab, err := avatar.ReadOptLevelCSV(f)
	if err != nil {
		t.Fatal(err)
	}
	g := tab.Grant(502, 1)
	if g == nil || len(g.Options) != 3 || !g.Options[0].Inferred || len(g.Skills) != 1 {
		t.Fatalf("502 +1 = %+v, want three inferred options and a skill", g)
	}
	if tab.Inferred() != 3 {
		t.Fatalf("Inferred() = %d, want 3", tab.Inferred())
	}
	if n := tab.DropInferred(); n != 3 {
		t.Fatalf("DropInferred() = %d, want 3", n)
	}
	if g := tab.Grant(502, 1); g == nil || len(g.Options) != 0 || len(g.Skills) != 1 {
		t.Fatalf("502 +1 after the drop = %+v, want its skill only", g)
	}
	if g := tab.Grant(501, 1); g == nil || len(g.Options) != 3 || g.Options[0].Inferred {
		t.Fatalf("501 +1 after the drop = %+v, want its own three options", g)
	}

	// The archive's text tables (UTF-8, trailing tab, the copyright line)
	// give the same rows.
	ta := write("refabilitybyitemoptleveldata.txt", "1\t1\t501\t0\t\r\n1\t2\t501\t1\t\r\n1\t3\t502\t0\t\r\n1\t4\t502\t1\t\r\n//Copyright\r\n")
	to := write("refmagicoptbyitemoptleveldata.txt", "1\t10\t5\t0\txxx\t\r\n2\t10\t6\t0\txxx\t\r\n3\t10\t5\t0\txxx\t\r\n")
	ts := write("refskillbyitemoptleveldata.txt", "4\t900\t\r\n")
	out2 := filepath.Join(dir, "iol2.csv")
	if err := exportItemOptLevel(out2, []string{ta, to, ts}); err != nil {
		t.Fatal(err)
	}
	raw, _ = os.ReadFile(out2)
	if want := "502,1,optinf,10,6\n502,1,skill,900,0\n"; !strings.Contains(string(raw), want) {
		t.Errorf("text export lacks %q:\n%s", want, raw)
	}
}
