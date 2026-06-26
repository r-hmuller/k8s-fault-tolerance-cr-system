package snapshot

import (
	"context"
	"os"
	"sync"
	"time"

	pb "github.com/r-hmuller/k8s-cr-daemon/protos"

	"github.com/r-hmuller/k8s-cr-daemon/config"
	"github.com/r-hmuller/k8s-cr-daemon/entity"
	"github.com/r-hmuller/k8s-cr-daemon/k8s"
	"github.com/rs/zerolog/log"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

func GenerateSnapshot(ctx context.Context, wg *sync.WaitGroup, snapshotRequest <-chan entity.SnapshotRequest) {
	for i := range snapshotRequest {
		wg.Add(1)
		go executeSnapshot(ctx, wg, i)
	}
	wg.Done()
}

func executeSnapshot(ctx context.Context, wg *sync.WaitGroup, snapshotRequest entity.SnapshotRequest) {
	defer wg.Done()

	log.Info().
		Str("namespace", snapshotRequest.Namespace).
		Str("service", snapshotRequest.ServiceName).
		Str("registry", snapshotRequest.RegistryName).
		Msg("Processing snapshot request")

	startTime := time.Now()

	kubeletSnapshot, err := k8s.GetPodByName(ctx, snapshotRequest)
	if err != nil {
		log.Error().Err(err).
			Str("namespace", snapshotRequest.Namespace).
			Str("service", snapshotRequest.ServiceName).
			Msg("Failed to find pod")
		if config.SendReplyMessage() {
			sendCompleteMessage(ctx, snapshotRequest, "failed")
		}
		return
	}

	log.Info().
		Str("namespace", kubeletSnapshot.Namespace).
		Str("pod", kubeletSnapshot.PodName).
		Str("container", kubeletSnapshot.ContainerName).
		Msg("Pod found for snapshot")

	snapshotFilePath, err := k8s.GenerateKubeletSnapshot(ctx, kubeletSnapshot)
	if err != nil {
		log.Error().Err(err).
			Str("namespace", kubeletSnapshot.Namespace).
			Str("pod", kubeletSnapshot.PodName).
			Msg("Failed to generate kubelet snapshot")
		if config.SendReplyMessage() {
			sendCompleteMessage(ctx, snapshotRequest, "failed")
		}
		return
	}

	err = k8s.GenerateOCIImageFromSnapshotFile(ctx, snapshotFilePath, kubeletSnapshot)
	if err != nil {
		log.Error().Err(err).
			Str("namespace", kubeletSnapshot.Namespace).
			Str("pod", kubeletSnapshot.PodName).
			Str("service", snapshotRequest.ServiceName).
			Msg("Failed to generate OCI image from snapshot file")
		// O tar não tem mais uso (o próximo intervalo gera um novo): sem esta
		// remoção, builds/pushes falhando em série (ex.: registry cheio)
		// acumulam tars de centenas de MB em /var/lib/kubelet/checkpoints até
		// derrubar o worker em DiskPressure (medido: 35 tars = 20GB).
		removeCheckpointFile(snapshotFilePath)
		if config.SendReplyMessage() {
			sendCompleteMessage(ctx, snapshotRequest, "failed")
		}
		return
	}

	removeCheckpointFile(snapshotFilePath)

	log.Info().
		Str("namespace", snapshotRequest.Namespace).
		Str("service", snapshotRequest.ServiceName).
		Str("duration", time.Since(startTime).String()).
		Msg("Snapshot request completed successfully")

	if config.SendReplyMessage() {
		sendCompleteMessage(ctx, snapshotRequest, "completed")
	}
}

func removeCheckpointFile(path string) {
	if err := os.Remove(path); err != nil {
		log.Warn().Err(err).
			Str("snapshot_file", path).
			Msg("Failed to delete kubelet checkpoint file")
	} else {
		log.Info().
			Str("snapshot_file", path).
			Msg("Kubelet checkpoint file deleted")
	}
}

func sendCompleteMessage(ctx context.Context, snapshot entity.SnapshotRequest, status string) {
	maxRetries := 5
	baseRetryDelay := time.Second

	for attempt := 1; attempt <= maxRetries; attempt++ {
		err := trySendCompleteMessage(ctx, snapshot, status)
		if err == nil {
			return
		}

		log.Warn().Err(err).
			Int("attempt", attempt).
			Int("maxRetries", maxRetries).
			Str("service", snapshot.ServiceName).
			Msg("Failed to send snapshot reply, retrying...")

		if attempt < maxRetries {
			// Exponential backoff: 1s, 2s, 4s, 8s
			retryDelay := baseRetryDelay * time.Duration(1<<(attempt-1))
			time.Sleep(retryDelay)
		}
	}

	log.Error().
		Str("service", snapshot.ServiceName).
		Str("status", status).
		Msg("Failed to send snapshot reply after all retries - interceptor may be stuck")
}

func trySendCompleteMessage(ctx context.Context, snapshot entity.SnapshotRequest, status string) error {
	replyTarget := os.Getenv("CR_DAEMON_REPLY_TARGET")

	// Create connection with timeout
	connCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	conn, err := grpc.NewClient(replyTarget, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		log.Error().Err(err).
			Str("target", replyTarget).
			Str("service", snapshot.ServiceName).
			Msg("Failed to connect to reply target")
		return err
	}
	defer conn.Close()

	client := pb.NewSnapshotRPCServiceClient(conn)
	reply, err := client.Reply(connCtx, &pb.ReplySnapshotRequest{
		Namespace:      snapshot.Namespace,
		ServiceName:    snapshot.ServiceName,
		RegistryName:   snapshot.RegistryName,
		SnapshotStatus: status,
		LatestRequest:  snapshot.LatestRequest,
	})
	if err != nil {
		log.Error().Err(err).
			Str("target", replyTarget).
			Str("service", snapshot.ServiceName).
			Str("status", status).
			Msg("Failed to send snapshot reply")
		return err
	}

	log.Info().
		Str("service", snapshot.ServiceName).
		Str("status", status).
		Bool("ack", reply.Response).
		Msg("Snapshot reply sent")

	return nil
}
