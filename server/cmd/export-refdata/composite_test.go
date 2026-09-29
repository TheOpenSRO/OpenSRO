package main

import "testing"

// compositeDescOf follows ExtractData's rule (round 632 review): 3/3/13/14
// only, Param2..5 whose value is 1. Synthetic columns, not a real row.
func TestCompositeDescOf(t *testing.T) {
	cols := make([]string, fParam1+40)
	for i := range cols {
		cols[i] = "-1"
	}
	cols[fParam1] = "3600"
	cols[fParam1+2] = "1"
	cols[fParam1+3] = "[UIL1:ITEM_A,A,3600,1],[UIU1:ITEM_B]"
	cols[fParam1+4] = "7"
	cols[fParam1+5] = "[UIL1:ITEM_C,A,1,1]" // Param3 is not 1: not a list
	if got := compositeDescOf(cols, "3", "3", "13", "14"); got != "[UIL1:ITEM_A,A,3600,1],[UIU1:ITEM_B]" {
		t.Errorf("3/3/13/14: %q", got)
	}
	if got := compositeDescOf(cols, "3", "3", "1", "8"); got != "" {
		t.Errorf("3/3/1/8 carries no list, got %q", got)
	}
}
