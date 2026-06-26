package crController

import (
	"context"
	"net"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/rs/zerolog/log"
	"google.golang.org/grpc"
	"interceptor-grpc/config"
	"interceptor-grpc/protos"
)

var IsRunningPendingRequestQueue atomic.Bool
var IsDoingSnapshot atomic.Bool
var IsRestoringSnapshot atomic.Bool
var IsContainerUnavailable atomic.Bool
var InFlightRequests sync.WaitGroup

// LastTrafficRelease marca (unix nano) o último desbloqueio de tráfego pós-
// snapshot — o início de uma janela de flush de backlog. O heartbeat usa como
// período de graça pra não confundir a sobrecarga do flush com pod morto.
var LastTrafficRelease atomic.Int64

// CanaryVerdictPending é setado quando o gate fecha (possível morte→restore)
// e só é limpo quando o canário completa uma leitura (veredito "limpo" ou
// "regressão+replay"). Enquanto pendente: o gate NÃO reabre e o snapshotter
// NÃO inicia snapshot — força a ordem restore → veredito → [replay] →
// tráfego → snapshot. Sem isso, um snapshot na fresta entre o restore e o
// veredito captura o estado revertido e marca o buffer como Snapshoted sem
// que os writes estejam nele (perda permanente — medido 2x com intervalo 180s).
var CanaryVerdictPending atomic.Bool

// ReprocessCallback is a function type for adding requests back to the queue.
// This callback is set by the interceptor package to avoid circular imports.
// It receives a request COPY: the live *http.Request/ResponseWriter die when
// the original handler returns and must never be stored or replayed.
type ReprocessCallback func(data config.RequestData)

var reprocessCallback ReprocessCallback
var drainConnectionsCallback func()

// RegisterReprocessCallback allows the interceptor package to register its AddRequestToQueue function
func RegisterReprocessCallback(callback ReprocessCallback) {
	reprocessCallback = callback
}

// RegisterDrainConnectionsCallback registra a função que fecha conexões keep-alive
// antes do checkpoint. Deve ser chamada antes do primeiro StopRequests.
func RegisterDrainConnectionsCallback(fn func()) {
	drainConnectionsCallback = fn
}

type server struct {
	protos.UnimplementedFailureServiceServer
	protos.UnimplementedSnapshotRPCServiceServer
}

func (s *server) StopRequests(_ context.Context, _ *protos.RestoreRequest) (*protos.RestoreResponse, error) {
	IsContainerUnavailable.Store(true)
	IsRestoringSnapshot.Store(true)
	// Aguarda todos os requests em voo terminarem, depois drena o pool de conexões
	// keep-alive. O CRIU requer zero conexões TCP abertas no momento do dump.
	InFlightRequests.Wait()
	if drainConnectionsCallback != nil {
		drainConnectionsCallback()
	}
	return &protos.RestoreResponse{Message: true}, nil
}

func (s *server) ReprocessRequests(_ context.Context, _ *protos.RestoreRequest) (*protos.RestoreResponse, error) {
	n := ReplayBufferedRequests()
	log.Info().Int("replayed", n).Msg("ReprocessRequests: buffered requests queued for replay")

	IsRestoringSnapshot.Store(false)
	IsContainerUnavailable.Store(false)

	return &protos.RestoreResponse{Message: true}, nil
}

// ReplayBufferedRequests re-enfileira (via callback do interceptor) todas as
// requests do buffer ainda não cobertas por um snapshot (Pending/Processed) —
// elas foram perdidas quando o backend restaurou um checkpoint anterior.
// Replay-only: o cliente original já foi respondido (ou desistiu), então o
// resultado é descartado. Cada entrada sai do buffer ao ser re-enfileirada
// (o replay re-registra sob um número novo). Retorna o total enfileirado.
// Chamado pelo gRPC ReprocessRequests e pelo heartbeat ao detectar recuperação.
func ReplayBufferedRequests() int {
	if reprocessCallback == nil {
		log.Warn().Msg("Reprocess callback not registered")
		return 0
	}
	reprocessableRequests := config.GetReprocessableRequests()
	for _, bufferedReq := range reprocessableRequests {
		reprocessCallback(bufferedReq.Data)
		config.RemoveRequestFromBuffer(bufferedReq.RequestNumber)
	}
	return len(reprocessableRequests)
}

func (s *server) Reply(_ context.Context, replySnapshot *protos.ReplySnapshotRequest) (*protos.AckResponse, error) {
	log.Info().
		Str("status", replySnapshot.SnapshotStatus).
		Str("service", replySnapshot.ServiceName).
		Uint64("latestRequest", replySnapshot.LatestRequest).
		Msg("Snapshot Reply received from daemon")

	config.UpdateRequestsToSnapshoted(replySnapshot.LatestRequest)

	IsDoingSnapshot.Store(false)
	config.SnapshotLock.Lock()
	config.IsSnapshotBeingTaken = false
	config.SnapshotLock.Unlock()
	LastTrafficRelease.Store(time.Now().UnixNano())

	log.Info().Msg("Snapshot complete, requests unblocked")

	return &protos.AckResponse{Response: true, Error: ""}, nil
}

func IsUnavailable() bool {
	// When checkpoint is disabled, IsRunningPendingRequestQueue is irrelevant:
	// the queue is only used during checkpoint/restore cycles. Including it here
	// when checkpoint is off causes a feedback loop where concurrent requests
	// pile into the queue faster than it drains (50ms/iteration).
	if !config.GetCheckpointEnabled() {
		return IsContainerUnavailable.Load()
	}
	return IsRunningPendingRequestQueue.Load() || IsDoingSnapshot.Load() || IsRestoringSnapshot.Load() || IsContainerUnavailable.Load()
}

func PodBeganRestarting(w http.ResponseWriter, _ *http.Request) {
	IsContainerUnavailable.Store(true)
	w.WriteHeader(http.StatusNoContent)
}

func PodEndedRestarting(w http.ResponseWriter, _ *http.Request) {
	IsContainerUnavailable.Store(false)
	w.WriteHeader(http.StatusNoContent)
}

func RunGRPCServer() {
	lis, err := net.Listen("tcp", config.GetSelfGrpcUrl())
	if err != nil {
		log.Fatal().Err(err).Str("port", config.GetSelfGrpcUrl()).Msg("Failed to listen on port")
	}

	s := grpc.NewServer()
	protos.RegisterFailureServiceServer(s, &server{})
	protos.RegisterSnapshotRPCServiceServer(s, &server{})
	if err := s.Serve(lis); err != nil {
		log.Fatal().Err(err).Msg("Failed to serve gRPC")
	}
}
