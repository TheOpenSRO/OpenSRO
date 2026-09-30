package gateway

import (
	"testing"
	"time"
)

// slowReaderBudget shortens SendBlockBudget/SendBlockWindow for
// TestASlowSteadyReaderIsClosedWithinItsBudget and returns the budget. (Run
// against a revision without the budget, this file is replaced by a stub that
// returns SendTimeout.)
func slowReaderBudget(t *testing.T) time.Duration {
	oldBudget, oldWindow := SendBlockBudget, SendBlockWindow
	SendBlockBudget, SendBlockWindow = 300*time.Millisecond, 3*time.Second
	t.Cleanup(func() { SendBlockBudget, SendBlockWindow = oldBudget, oldWindow })
	return SendBlockBudget
}
