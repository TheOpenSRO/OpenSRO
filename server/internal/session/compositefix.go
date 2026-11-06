package session

import (
	"strings"

	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
)

// Round 864 (the user): a composite descriptor some archives carry short.
//
// MEASURED: ITEM_MALL_PREMIUM_VIETNAM_GOLDTIME_PLUS's descriptor lists the
// same three daily fills as ITEM_MALL_PREMIUM_GOLDTIME's -- the 100 %
// resurrection scroll (1 a day) after the UIU1 entry, then the reverse return
// and the instant return (3 a day each). An archive whose row lacks the
// resurrection entry (the one prod's items were imported from does) gives the
// PLUS premium two fills; compositeDescOf puts the entry back where the full
// row has it, so the window lists all three and the arrival repair
// (compositerepair.go) restores the missing grant.
var compositeDescFixes = map[string]compositeDescFix{
	"ITEM_MALL_PREMIUM_VIETNAM_GOLDTIME_PLUS": {
		missing: "UIL1:ITEM_MALL_RESURRECTION_100P_SCROLL",
		entry:   "[UIL1:ITEM_MALL_RESURRECTION_100P_SCROLL, A, 86400, 1]",
		after:   "[UIU1:ITEM_PRE_GOLTAM_4W]",
	},
}

type compositeDescFix struct {
	missing string // the entry's fourCC and item, as the full row spells them
	entry   string // the whole entry to insert
	after   string // the entry it follows in the full row; at the front when absent
}

// compositeDescOf is a composite's descriptor with compositeDescFixes applied.
func compositeDescOf(it *refdata.Item) string {
	if it == nil {
		return ""
	}
	desc := it.CompositeDesc
	fix, ok := compositeDescFixes[it.CodeName]
	if !ok || desc == "" || strings.Contains(strings.ReplaceAll(desc, " ", ""), strings.ReplaceAll(fix.missing, " ", "")) {
		return desc
	}
	if i := strings.Index(desc, fix.after); i >= 0 {
		at := i + len(fix.after)
		return desc[:at] + "," + fix.entry + desc[at:]
	}
	return fix.entry + "," + desc
}
