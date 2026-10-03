package gateway

import (
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/proto"
)

// The round-662 API the queue tests use, kept in this one file so that the
// tests build against a revision without the queue: for the negative, this
// file is replaced by a stub (sendBatch sends one frame at a time, the queue
// limit is not there to set, and there is no queue to free).

// sendBatch queues ps as one batch.
func sendBatch(s *Session, ps ...*proto.Packet) error { return s.SendBatch(ps...) }

// setQueueLimit sets SendQueueLimit for one test.
func setQueueLimit(t *testing.T, n int) {
	old := SendQueueLimit
	SendQueueLimit = n
	t.Cleanup(func() { SendQueueLimit = old })
}

// queueFreed reports whether s's writer has returned and its queue is gone.
func queueFreed(s *Session) bool {
	select {
	case <-s.writerDone:
	default:
		return false
	}
	s.outMu.Lock()
	defer s.outMu.Unlock()
	return s.out == nil && s.inFlight == 0
}
