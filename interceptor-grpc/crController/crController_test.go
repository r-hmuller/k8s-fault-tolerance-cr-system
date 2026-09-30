package crController

import (
	"context"
	"testing"

	"interceptor-grpc/config"
	"interceptor-grpc/protos"
)

func isReprocessable(num uint64) bool {
	for _, r := range config.GetReprocessableRequests() {
		if r.RequestNumber == num {
			return true
		}
	}
	return false
}

func sendReply(t *testing.T, status string, latest uint64) {
	t.Helper()
	IsDoingSnapshot.Store(true)
	_, err := (&server{}).Reply(context.Background(), &protos.ReplySnapshotRequest{
		SnapshotStatus: status,
		LatestRequest:  latest,
	})
	if err != nil {
		t.Fatalf("Reply returned error: %v", err)
	}
	if IsDoingSnapshot.Load() {
		t.Fatalf("Reply(%q) did not release traffic", status)
	}
}

// Um snapshot que falhou no daemon não contém as requisições: elas precisam
// continuar reprocessáveis, senão a limpeza periódica as descarta e uma
// restauração posterior as perde.
func TestReplyFailedKeepsRequestsReprocessable(t *testing.T) {
	num := config.SaveRequestToBuffer(config.RequestData{Method: "POST", Path: "/"})
	config.UpdateRequestToProcessed(num)

	sendReply(t, "failed", num)

	if !isReprocessable(num) {
		t.Fatalf("request %d was marked Snapshoted after a failed snapshot", num)
	}
}

func TestReplyCompletedMarksRequestsSnapshoted(t *testing.T) {
	num := config.SaveRequestToBuffer(config.RequestData{Method: "POST", Path: "/"})
	config.UpdateRequestToProcessed(num)

	sendReply(t, "completed", num)

	if isReprocessable(num) {
		t.Fatalf("request %d still reprocessable after a completed snapshot", num)
	}
}
