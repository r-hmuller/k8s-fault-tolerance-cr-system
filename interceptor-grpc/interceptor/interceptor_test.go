package interceptor

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"interceptor-grpc/config"
	"interceptor-grpc/crController"
)

func waitFor(t *testing.T, description string, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", description)
		}
		time.Sleep(time.Millisecond)
	}
}

func receive[T any](t *testing.T, ch <-chan T) T {
	t.Helper()
	select {
	case value := <-ch:
		return value
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for channel")
		var zero T
		return zero
	}
}

func startQueue(t *testing.T, applicationURL string, checkpointEnabled bool) {
	t.Helper()
	t.Setenv("APPLICATION_URL", applicationURL)
	t.Setenv("DIRECT_APPLICATION_URL", "")
	t.Setenv("CHECKPOINT_ENABLED", strconv.FormatBool(checkpointEnabled))
	crController.IsContainerUnavailable.Store(false)
	crController.IsDoingSnapshot.Store(false)
	crController.IsRestoringSnapshot.Store(false)
	crController.IsRunningPendingRequestQueue.Store(false)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		processQueue(ctx)
	}()
	t.Cleanup(func() {
		cancel()
		receive(t, done)
		DrainConnections()
		crController.IsRunningPendingRequestQueue.Store(false)
		crController.IsDoingSnapshot.Store(false)
		crController.IsContainerUnavailable.Store(false)
		if n := QueueLength.Load(); n != 0 {
			t.Errorf("queue still contains %d entries", n)
		}
	})
}

func TestQueueIsSequentialAndNormalRequestsStayParallel(t *testing.T) {
	for _, checkpointEnabled := range []bool{true, false} {
		t.Run(fmt.Sprintf("checkpoint=%t", checkpointEnabled), func(t *testing.T) {
			queueStarted := make(chan string, 4)
			normalStarted := make(chan struct{}, 2)
			queueRelease := make(chan struct{})
			normalRelease := make(chan struct{})
			var queueReleaseOnce, normalReleaseOnce sync.Once
			var active, maximum atomic.Int32
			backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if strings.HasPrefix(r.URL.Path, "/normal") {
					normalStarted <- struct{}{}
					<-normalRelease
				} else {
					n := active.Add(1)
					for old := maximum.Load(); n > old && !maximum.CompareAndSwap(old, n); old = maximum.Load() {
					}
					defer active.Add(-1)
					queueStarted <- r.URL.Path
					if r.URL.Path == "/replay-1" {
						<-queueRelease
					}
				}
				w.WriteHeader(http.StatusCreated)
				_, _ = io.WriteString(w, r.URL.Path)
			}))
			t.Cleanup(backend.Close)
			startQueue(t, backend.URL, checkpointEnabled)
			t.Cleanup(func() {
				queueReleaseOnce.Do(func() { close(queueRelease) })
				normalReleaseOnce.Do(func() { close(normalRelease) })
			})

			// O primeiro item é replay-only; o segundo tem um cliente esperando.
			secondResult := make(chan config.Result, 1)
			AddRequestToQueue(QueueHttpRequest{Data: config.RequestData{Method: http.MethodPost, Path: "/replay-1"}})
			AddRequestToQueue(QueueHttpRequest{Data: config.RequestData{Method: http.MethodPost, Path: "/replay-2"}, RespCh: secondResult})
			if got := receive(t, queueStarted); got != "/replay-1" {
				t.Fatalf("first request = %q", got)
			}

			// Uma requisição nova deve aguardar o replay, inclusive com checkpoint desligado.
			newDone := make(chan *httptest.ResponseRecorder, 1)
			go func() {
				w := httptest.NewRecorder()
				Handler(w, httptest.NewRequest(http.MethodPost, "/new", strings.NewReader("value")))
				newDone <- w
			}()
			waitFor(t, "new request queued behind replay", func() bool { return QueueLength.Load() == 2 })
			select {
			case got := <-queueStarted:
				t.Fatalf("request %q overtook unfinished replay", got)
			case <-time.After(100 * time.Millisecond):
			}
			queueReleaseOnce.Do(func() { close(queueRelease) })
			for _, want := range []string{"/replay-2", "/new"} {
				if got := receive(t, queueStarted); got != want {
					t.Fatalf("request = %q, want %q", got, want)
				}
			}
			res := receive(t, secondResult)
			if res.Status != http.StatusCreated || string(res.Body) != "/replay-2" {
				t.Fatalf("queued response = %+v", res)
			}
			newResponse := receive(t, newDone)
			if newResponse.Code != http.StatusCreated || newResponse.Body.String() != "/new" {
				t.Fatalf("new response = %d %q", newResponse.Code, newResponse.Body.String())
			}
			if got := maximum.Load(); got != 1 {
				t.Fatalf("maximum queue concurrency = %d, want 1", got)
			}
			waitFor(t, "queue drain to finish", func() bool {
				return QueueLength.Load() == 0 && !crController.IsRunningPendingRequestQueue.Load()
			})

			// Ambas devem chegar ao backend antes de qualquer resposta ser liberada.
			// Isso detecta uma serialização acidental das requisições normais.
			normalDone := make(chan int, 2)
			for i := 0; i < 2; i++ {
				go func(i int) {
					w := httptest.NewRecorder()
					Handler(w, httptest.NewRequest(http.MethodGet, fmt.Sprintf("/normal-%d", i), nil))
					normalDone <- w.Code
				}(i)
			}
			receive(t, normalStarted)
			receive(t, normalStarted)
			normalReleaseOnce.Do(func() { close(normalRelease) })
			for i := 0; i < 2; i++ {
				if got := receive(t, normalDone); got != http.StatusCreated {
					t.Fatalf("normal response status = %d", got)
				}
			}
		})
	}
}

func TestSnapshotPausesQueueBetweenRequests(t *testing.T) {
	started := make(chan string, 2)
	release := make(chan struct{})
	var releaseOnce sync.Once
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started <- r.URL.Path
		if r.URL.Path == "/first" {
			<-release
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	t.Cleanup(backend.Close)
	startQueue(t, backend.URL, true)
	t.Cleanup(func() { releaseOnce.Do(func() { close(release) }) })
	first := make(chan config.Result, 1)
	second := make(chan config.Result, 1)
	AddRequestToQueue(QueueHttpRequest{Data: config.RequestData{Method: http.MethodPost, Path: "/first"}, RespCh: first})
	AddRequestToQueue(QueueHttpRequest{Data: config.RequestData{Method: http.MethodPost, Path: "/second"}, RespCh: second})
	if got := receive(t, started); got != "/first" {
		t.Fatalf("first request = %q", got)
	}
	crController.IsDoingSnapshot.Store(true)
	releaseOnce.Do(func() { close(release) })
	receive(t, first)
	crController.InFlightRequests.Wait()
	if got := QueueLength.Load(); got != 1 {
		t.Fatalf("queue length during snapshot = %d, want 1", got)
	}
	select {
	case got := <-started:
		t.Fatalf("request %q dispatched during snapshot", got)
	case <-time.After(100 * time.Millisecond):
	}
	crController.IsDoingSnapshot.Store(false)
	if got := receive(t, started); got != "/second" {
		t.Fatalf("resumed request = %q", got)
	}
	if got := receive(t, second); got.Status != http.StatusNoContent {
		t.Fatalf("resumed response = %+v", got)
	}
}
