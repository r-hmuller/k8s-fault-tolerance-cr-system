package config

import (
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

const (
	Pending = iota
	Processed
	Snapshoted
)

// BufferedRequest stores a copy of the request data for potential reprocessing.
// It must never hold the live *http.Request or http.ResponseWriter: both die
// when the handler returns (Go finalizes the response and recycles them).
type BufferedRequest struct {
	Data          RequestData
	RequestNumber uint64
	State         int
}

var processedMap sync.Map
var requestsMap sync.Map
var requestNumber atomic.Uint64
var requestsMapMutex sync.RWMutex

func GetLatestRequestNumber() uint64 {
	return requestNumber.Load()
}

// SaveRequestToBuffer stores a copy of the request data for potential reprocessing
func SaveRequestToBuffer(data RequestData) uint64 {
	num := requestNumber.Add(1)

	bufferedReq := &BufferedRequest{
		Data:          data,
		RequestNumber: num,
		State:         Pending,
	}

	requestsMapMutex.Lock()
	requestsMap.Store(num, bufferedReq)
	requestsMapMutex.Unlock()

	processedMap.Store(num, Pending)
	return num
}

func UpdateRequestToProcessed(number uint64) {
	processedMap.Store(number, Processed)

	// Also update the buffered request state
	requestsMapMutex.Lock()
	if val, ok := requestsMap.Load(number); ok {
		if bufferedReq, ok := val.(*BufferedRequest); ok {
			bufferedReq.State = Processed
		}
	}
	requestsMapMutex.Unlock()
}

func UpdateRequestsToSnapshoted(latestRequest uint64) {
	processedMap.Range(func(key, value interface{}) bool {
		// Use <= to include the request with ID equal to latestRequest
		if key.(uint64) <= latestRequest {
			processedMap.Store(key, Snapshoted)

			// Also update the buffered request state
			requestsMapMutex.Lock()
			if val, ok := requestsMap.Load(key); ok {
				if bufferedReq, ok := val.(*BufferedRequest); ok {
					bufferedReq.State = Snapshoted
				}
			}
			requestsMapMutex.Unlock()
		}
		return true
	})
}

func ClearRequestsMap() {
	tick := time.Tick(60 * time.Second)
	for range tick {
		var keysToDelete []interface{}

		// Snapshoted: sempre coletável (já está durável no checkpoint).
		// Processed: só coletável quando checkpoint está DESLIGADO (evita memory
		// leak em runs longos sem snapshot). Com checkpoint ligado, Processed é
		// exatamente o conjunto que o replay re-aplica se o backend restaurar um
		// checkpoint antigo — coletá-lo entre snapshots quebraria a recuperação.
		SnapshotLock.Lock()
		snapshotInProgress := IsSnapshotBeingTaken
		SnapshotLock.Unlock()

		processedMap.Range(func(key, value interface{}) bool {
			state := value.(int)
			if state == Snapshoted {
				keysToDelete = append(keysToDelete, key)
			} else if state == Processed && !snapshotInProgress && !GetCheckpointEnabled() {
				keysToDelete = append(keysToDelete, key)
			}
			return true
		})

		requestsMapMutex.Lock()
		for _, key := range keysToDelete {
			processedMap.Delete(key)
			requestsMap.Delete(key)
		}
		requestsMapMutex.Unlock()
	}
}

// GetReprocessableRequests returns all requests that are pending or processed but not snapshoted
func GetReprocessableRequests() []*BufferedRequest {
	var reprocessableRequests []*BufferedRequest

	requestsMapMutex.RLock()
	defer requestsMapMutex.RUnlock()

	processedMap.Range(func(key, value interface{}) bool {
		state := value.(int)
		if state == Pending || state == Processed {
			if val, ok := requestsMap.Load(key); ok {
				if bufferedReq, ok := val.(*BufferedRequest); ok {
					reprocessableRequests = append(reprocessableRequests, bufferedReq)
				}
			}
		}
		return true
	})

	sort.Slice(reprocessableRequests, func(i, j int) bool {
		return reprocessableRequests[i].RequestNumber < reprocessableRequests[j].RequestNumber
	})

	return reprocessableRequests
}

// GetRequestStats returns counts of requests in each state for monitoring
func GetRequestStats() (pending, processed, snapshoted int) {
	processedMap.Range(func(key, value interface{}) bool {
		switch value.(int) {
		case Pending:
			pending++
		case Processed:
			processed++
		case Snapshoted:
			snapshoted++
		}
		return true
	})
	return
}

// RemoveRequestFromBuffer drops an entry after it was handed back to the
// recovery queue: the replay re-buffers it under a new number, so keeping the
// old entry as Pending would replay it again on every future ReprocessRequests
// and leak (ClearRequestsMap never collects Pending).
func RemoveRequestFromBuffer(requestNum uint64) {
	requestsMapMutex.Lock()
	processedMap.Delete(requestNum)
	requestsMap.Delete(requestNum)
	requestsMapMutex.Unlock()
}
