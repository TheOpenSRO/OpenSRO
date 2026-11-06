package session

import (
	"strings"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
)

// Round 864: the PLUS premium's short descriptor gets its resurrection fill
// back, in the full row's place; a full row and other items are untouched.
func TestCompositeDescOfRestoresPlusResurrection(t *testing.T) {
	short := "[UIU1:ITEM_PRE_GOLTAM_4W],[USU1:SKILL_MALL_PRE_APRU_4W_01],[UIL1:ITEM_MALL_REVERSE_RETURN_SCROLL, A, 86400, 3],[UIL1:ITEM_MALL_RETURN_SCROLL_HIGH_SPEED, A, 86400, 3],[BFI1:ITEM_MALL_BOOTH_MOB_MANGYANG,A,2419200],[UQL1:QSP_ALL_POTION_3, A, 2419200, 4]"
	full := "[UIU1:ITEM_PRE_GOLTAM_4W],[UIL1:ITEM_MALL_RESURRECTION_100P_SCROLL, A, 86400, 1],[USU1:SKILL_MALL_PRE_APRU_4W_01],[UIL1:ITEM_MALL_REVERSE_RETURN_SCROLL, A, 86400, 3],[UIL1:ITEM_MALL_RETURN_SCROLL_HIGH_SPEED, A, 86400, 3],[BFI1:ITEM_MALL_BOOTH_MOB_MANGYANG,A,2419200],[UQL1:QSP_ALL_POTION_3, A, 2419200, 4]"

	plus := &refdata.Item{ID: 35567, CodeName: "ITEM_MALL_PREMIUM_VIETNAM_GOLDTIME_PLUS", CompositeDesc: short}
	got := compositeDescOf(plus)
	if got != full {
		t.Fatalf("PLUS short row fixed to\n%s\nwant\n%s", got, full)
	}
	entries, err := parseCompositeDesc(got)
	if err != nil {
		t.Fatal(err)
	}
	var fills []string
	for _, e := range entries {
		if e.fourCC == "UIL1" {
			fills = append(fills, e.code)
		}
	}
	if strings.Join(fills, ",") != "ITEM_MALL_RESURRECTION_100P_SCROLL,ITEM_MALL_REVERSE_RETURN_SCROLL,ITEM_MALL_RETURN_SCROLL_HIGH_SPEED" {
		t.Errorf("PLUS fills %v, want resurrection, reverse return, instant return", fills)
	}

	// A full row is left as it is (no second resurrection entry).
	plus.CompositeDesc = full
	if got := compositeDescOf(plus); got != full {
		t.Errorf("full PLUS row changed to %s", got)
	}
	// NEGATIVE: another composite with no resurrection entry is not touched.
	other := &refdata.Item{ID: 1, CodeName: "ITEM_MALL_SOMETHING_ELSE", CompositeDesc: short}
	if got := compositeDescOf(other); got != short {
		t.Errorf("an item without a fix changed: %s", got)
	}
}
