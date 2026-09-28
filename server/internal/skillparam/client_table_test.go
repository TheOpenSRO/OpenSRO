package skillparam

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// clientRun is the CLIENT's Param-block run table, read out of sro_client.exe's
// own parser, GlobalDataManager::FUN_009bbca0 (round 618's review; extracted on
// the RE box as /var/tmp/rv618/client_run.json and spot-checked against the
// decompile: bldr +5, fitp +2, lnks +5, cbuf +1, and ssou and sstt both
// return). The buff bar (client/scripts/ui/hud/skill_buff_catalog.gd) walks
// the client's skilldata with it. It is NOT this package's Run -- that is the
// server's parser (0x587630) -- and the two differ: see clientOnly and
// clientDiffers below.
var clientRun = map[Code]int{
	"abir": 3, "abnb": 2, "agac": 3, "alcu": 2, "ao": 1, "apau": 3, "apru": 3, "ar": 3, "atca": 3,
	"att": 6, "bbuf": 1, "bcnt": 2, "bgra": 3, "bl": 6, "bldr": 5, "br": 3, "bu": 4, "ca": 4,
	"cabf": 2, "cbuf": 1, "chcr": 2, "chpi": 2, "chst": 2, "civi": 2, "ck": 2, "cmcr": 2,
	"cnsm": 4, "cr": 3, "cshp": 7, "csit": 5, "csmd": 5, "csmp": 7, "cspd": 5, "cssr": 5,
	"csum": 2, "cura": 2, "curl": 4, "curt": 3, "da": 2, "dac": 2, "dar": 3, "dcmp": 2, "dcri": 2,
	"defp": 4, "defr": 3, "dgmp": 2, "dmgr": 5, "dmgt": 3, "dn": 5, "dra2": 2, "dru": 3,
	"dru2": 3, "ds": 5, "dspl": 3, "dtnt": 3, "dtt": 3, "dttp": 3, "dura": 2, "efr": 7, "efta": 1,
	"er": 3, "es": 4, "eshp": 1, "esht": 3, "expi": 3, "expu": 3, "fb": 3, "fe": 4, "fitp": 2,
	"fz": 3, "gdr": 2, "getv": 2, "heal": 5, "hel2": 5, "hide": 4, "hitm": 1, "hntp": 1, "hpi": 3,
	"hr": 3, "hst2": 2, "hst3": 2, "hste": 2, "hwir": 2, "hwit": 2, "iddm": 2, "inti": 3,
	"irgc": 3, "iwky": 1, "jobs": 2, "kb": 3, "ko": 3, "lfst": 2, "lkag": 3, "lkcp": 2, "lkdd": 2,
	"lkdh": 4, "lkdr": 4, "lks2": 1, "lnks": 5, "luck": 2, "mc": 3, "mcap": 3, "mom": 5, "mpi": 3,
	"mscc": 2, "msch": 3, "msid": 2, "msr": 3, "mstc": 2, "mwdt": 2, "mwhh": 2, "mwhs": 2,
	"mwmh": 2, "mwtt": 2, "my": 5, "nbuf": 1, "nmf": 1, "nmh": 1, "odar": 3, "onff": 3, "ovl2": 2,
	"pao": 2, "pcdu": 3, "pchr": 2, "pdm2": 2, "pdmg": 2, "php1": 1, "pls2": 5, "pmdg": 5,
	"pmdp": 5, "pmhp": 5, "pmmp": 5, "pmp1": 1, "pola": 3, "ps": 4, "puls": 2, "pw": 5, "pwdt": 2,
	"pwtt": 2, "qest": 5, "rcur": 2, "real": 4, "reat": 3, "reqa": 2, "reqc": 2, "reqi": 3,
	"reqn": 1, "resu": 3, "rhru": 3, "rmut": 2, "rpkt": 1, "rsag": 1, "rt": 4, "ru": 2, "saps": 3,
	"scls": 2, "se": 4, "setv": 4, "skc": 4, "sl": 4, "slcc": 1, "smac": 3, "spda": 3, "spi": 2,
	"ssou": 1, "sstt": 1, "st": 4, "stns": 4, "stri": 3, "summ": 6, "tant": 3, "tb": 5, "tcmd": 3,
	"tctc": 1, "tel2": 3, "tel3": 3, "tel4": 3, "tele": 3, "terd": 2, "thld": 2, "thrd": 2,
	"tkss": 2, "tnt2": 3, "tpad": 2, "tpdd": 2, "tran": 3, "trap": 1, "zb": 3,
}

// Codes the client parser has and the server's does not.
var clientOnly = []Code{"agac", "bcnt", "cabf", "chpi", "chst", "civi", "csum", "dac", "dra2", "dspl",
	"hel2", "iddm", "iwky", "jobs", "pls2", "rsag", "smac", "sstt", "tel4"}

// Codes both parsers have, with different run lengths (client, server).
var clientDiffers = map[Code][2]int{"bldr": {5, 4}, "fitp": {2, 1}}

// TestClientRunTableIsTheClients fails when skill_buff_catalog.gd's RUN table
// drifts from the client parser's table -- in any code or length -- and when
// the recorded client table stops differing from Run exactly as documented
// (someone "syncing" it to the server's). A drifted length derails the walk
// from that code on, silently.
//
// It reads the .gd at run time, which Go's test cache does not see: run it
// with -count=1.
func TestClientRunTableIsTheClients(t *testing.T) {
	path := filepath.Join("..", "..", "..", "client", "scripts", "ui", "hud", "skill_buff_catalog.gd")
	src, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading %s: %v", path, err)
	}
	text := string(src)
	start := strings.Index(text, "const RUN := {")
	if start < 0 {
		t.Fatalf("%s has no `const RUN := {` block", path)
	}
	end := strings.Index(text[start:], "\n}")
	if end < 0 {
		t.Fatalf("%s: the RUN block never closes", path)
	}
	pair := regexp.MustCompile(`"([a-zA-Z0-9]{1,4})":\s*(\d+)`)
	gd := map[Code]int{}
	for _, m := range pair.FindAllStringSubmatch(text[start:start+end], -1) {
		n, _ := strconv.Atoi(m[2])
		if _, dup := gd[Code(m[1])]; dup {
			t.Errorf("the .gd RUN lists %q twice", m[1])
		}
		gd[Code(m[1])] = n
	}
	if len(gd) != len(clientRun) {
		t.Errorf("the .gd RUN has %d codes, the client parser %d", len(gd), len(clientRun))
	}
	for c, n := range clientRun {
		if got, ok := gd[c]; !ok {
			t.Errorf("the .gd RUN lacks %q (run %d)", c, n)
		} else if got != n {
			t.Errorf("the .gd RUN[%q] = %d, the client parser's = %d", c, got, n)
		}
	}
	for c := range gd {
		if _, ok := clientRun[c]; !ok {
			t.Errorf("the .gd RUN has %q, which the client parser does not", c)
		}
	}

	// The recorded client table against the server's, difference by difference.
	only := map[Code]bool{}
	for _, c := range clientOnly {
		only[c] = true
	}
	for c, n := range clientRun {
		sv, inServer := Run[c]
		switch {
		case only[c]:
			if inServer {
				t.Errorf("%q is listed client-only but the server's Run has it", c)
			}
		case !inServer:
			t.Errorf("%q is in the client table but neither in Run nor listed client-only", c)
		case clientDiffers[c] != [2]int{}:
			if d := clientDiffers[c]; d[0] != n || d[1] != sv {
				t.Errorf("%q: client %d / server %d, recorded as %v", c, n, sv, d)
			}
		case n != sv:
			t.Errorf("%q: client %d, server %d -- an unrecorded difference", c, n, sv)
		}
	}
	for c := range Run {
		if _, ok := clientRun[c]; !ok {
			t.Errorf("the server's Run has %q, which the client table lacks", c)
		}
	}
	for _, tag := range []Code{"cbuf", "nbuf", "bbuf"} {
		if clientRun[tag] != 1 {
			t.Errorf("%q is expected to be a run-1 marker in the client parser", tag)
		}
	}
	if clientRun["lnks"] != 5 {
		t.Errorf("lnks is a run of 5 in the client parser, not %d", clientRun["lnks"])
	}
}
