package interceptor

import (
	"errors"
	"sync"
	"sync/atomic"

	"interceptor-grpc/config"
)

var QueueLength = atomic.Uint32{}
var queue = make([]QueueHttpRequest, 0)
var queueMutex sync.Mutex

func AddRequestToQueue(queueRequest QueueHttpRequest) {
	queueMutex.Lock()
	defer queueMutex.Unlock()

	queue = append(queue, queueRequest)
	QueueLength.Add(1)
}

// AddToQueueForReprocess enqueues a buffered request copy for replay after
// recovery. RespCh stays nil: the original client was already answered (or is
// long gone), so the result is applied to the application and discarded.
func AddToQueueForReprocess(data config.RequestData) {
	AddRequestToQueue(QueueHttpRequest{Data: data})
}

func GetRequestFromQueue() (QueueHttpRequest, error) {
	queueMutex.Lock()
	defer queueMutex.Unlock()

	if len(queue) == 0 {
		return QueueHttpRequest{}, errors.New("queue is empty")
	}
	request := queue[0]
	queue = queue[1:]
	QueueLength.Store(uint32(len(queue)))
	return request, nil
}
