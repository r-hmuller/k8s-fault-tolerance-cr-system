package snapshotter

import (
	"context"
	"interceptor-grpc/config"
	"interceptor-grpc/crController"
	"interceptor-grpc/interceptor"
	"interceptor-grpc/protos"
	"sync/atomic"
	"time"

	"github.com/rs/zerolog/log"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

// Espera máxima pela drenagem da fila de recuperação antes de um snapshot.
// Snapshot no meio da drenagem empilha bloqueio sobre o backlog do replay e
// estica a janela efetiva de recuperação; melhor esperar a fila zerar —
// mas com teto, pra cadência e durabilidade não ficarem reféns da fila.
var maxQueueWait = 2 * time.Minute

var snapshotStartTime time.Time
var replyTimeout = 4 * time.Minute

// snapshotGeneration identifies which snapshot a safety-net goroutine was armed for.
// Without it, the goroutine from snapshot N (sleeping replyTimeout, which can coincide
// with the checkpoint interval) wakes up exactly when snapshot N+1 starts, sees the
// global IsDoingSnapshot flag set and releases N+1's locks, unblocking traffic while
// the daemon is still dumping/pushing.
var snapshotGeneration atomic.Uint64

func GenerateSnapshots(ctx context.Context) {
	tick := time.Tick(time.Duration(config.GetCheckpointInterval()) * time.Second)
	maxSnapshotDuration := 5 * time.Minute
	for range tick {
		// NUNCA snapshotar com o gate fechado (outage/recuperação em curso):
		// um checkpoint entre o restore e o replay captura o estado REVERTIDO
		// e marca o buffer como Snapshoted sem que os writes estejam nele —
		// perda permanente (medido no v5, quando a detecção do canário atrasou).
		if crController.IsContainerUnavailable.Load() {
			log.Warn().Msg("Snapshot skipped: container unavailable (outage/recovery in progress)")
			continue
		}
		if crController.CanaryVerdictPending.Load() {
			// Houve fechamento de gate (possível restore) e o canário ainda não
			// deu veredito: snapshotar agora poderia capturar estado revertido
			// e lavar o buffer (writes perdidos). Espera o veredito.
			log.Warn().Msg("Snapshot skipped: canary verdict pending after gate closure")
			continue
		}

		// Lock before checking to prevent race condition
		config.SnapshotLock.Lock()
		if config.IsSnapshotBeingTaken {
			elapsed := time.Since(snapshotStartTime)
			if elapsed > maxSnapshotDuration {
				config.SnapshotLock.Unlock()
				log.Warn().
					Dur("elapsed", elapsed).
					Dur("max_duration", maxSnapshotDuration).
					Msg("Snapshot has been in progress for too long, forcing lock release")
				releaseSnapshotLocks()
				continue
			}
			config.SnapshotLock.Unlock()
			continue
		}
		config.IsSnapshotBeingTaken = true
		snapshotStartTime = time.Now()
		snapshotGeneration.Add(1)
		config.SnapshotLock.Unlock()

		if waited := waitRecoveryQueueDrain(); waited > 0 {
			log.Info().Dur("waited", waited).Msg("Snapshot deferred until recovery queue drained")
		}

		log.Info().Msg("Starting snapshot")
		generateSnapshot(ctx)
	}
}

// waitRecoveryQueueDrain segura o início do snapshot enquanto a fila de
// recuperação (replay pós-restore) ainda tem itens, até maxQueueWait.
// Retorna quanto tempo esperou.
func waitRecoveryQueueDrain() time.Duration {
	start := time.Now()
	for interceptor.QueueLength.Load() > 0 && time.Since(start) < maxQueueWait {
		time.Sleep(2 * time.Second)
	}
	return time.Since(start).Round(time.Second)
}

// releaseSnapshotLocks releases all snapshot-related locks in case of failure
func releaseSnapshotLocks() {
	crController.IsDoingSnapshot.Store(false)
	config.SnapshotLock.Lock()
	config.IsSnapshotBeingTaken = false
	config.SnapshotLock.Unlock()
	// Também é um desbloqueio de tráfego: marca o início da janela de flush.
	crController.LastTrafficRelease.Store(time.Now().UnixNano())
}

func generateSnapshot(ctx context.Context) {
	// Block new requests first
	crController.IsDoingSnapshot.Store(true)
	log.Info().Msg("Snapshot started: blocking new requests")

	// Wait for all in-flight HTTP requests to complete
	waitDone := make(chan struct{})
	go func() {
		crController.InFlightRequests.Wait()
		close(waitDone)
	}()

	maxWaitTime := time.Duration(config.GetSnapshotDrainTimeout()) * time.Second
	select {
	case <-waitDone:
		log.Info().Dur("drain_timeout", maxWaitTime).Msg("All in-flight requests drained")
	case <-time.After(maxWaitTime):
		log.Warn().Dur("drain_timeout", maxWaitTime).Msg("Timeout waiting for in-flight requests, proceeding with snapshot")
	}

	snapshotRequest := &protos.CreateSnapshotRequest{
		ServiceName:   config.GetServiceName(),
		RegistryName:  config.GetRegistryName(),
		Namespace:     config.GetNamespace(),
		LatestRequest: config.GetLatestRequestNumber(),
	}

	log.Info().
		Str("service", snapshotRequest.ServiceName).
		Str("namespace", snapshotRequest.Namespace).
		Uint64("latestRequest", snapshotRequest.LatestRequest).
		Msg("Sending snapshot request to daemon")

	// Create connection with timeout
	connCtx, connCancel := context.WithTimeout(ctx, 10*time.Second)
	defer connCancel()

	conn, err := grpc.NewClient(config.GetDaemonGrpcUrl(), grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		log.Err(err).Str("url", config.GetDaemonGrpcUrl()).Msg("Failed to connect to daemon gRPC server")
		releaseSnapshotLocks()
		return
	}
	defer conn.Close()

	c := protos.NewSnapshotRPCServiceClient(conn)

	// Use timeout context for the Create call
	response, err := c.Create(connCtx, snapshotRequest)
	if err != nil {
		log.Err(err).Msg("Failed to send snapshot request")
		releaseSnapshotLocks()
		return
	}
	if response.GetResponse() != true {
		log.Error().Str("error", response.GetError()).Msg("Daemon rejected snapshot request")
		releaseSnapshotLocks()
		return
	}

	log.Info().Msg("Snapshot request accepted by daemon, waiting for Reply")

	// Safety net: release locks if Reply() is not received in time.
	// Without this, a daemon failure after Create() leaves the system blocked indefinitely.
	// Generation-guarded: only releases the snapshot it was armed for, never a later one.
	gen := snapshotGeneration.Load()
	go func() {
		time.Sleep(replyTimeout)
		if crController.IsDoingSnapshot.Load() && snapshotGeneration.Load() == gen {
			log.Warn().
				Dur("timeout", replyTimeout).
				Uint64("generation", gen).
				Msg("Reply() not received in time, forcing lock release")
			releaseSnapshotLocks()
		}
	}()
}
