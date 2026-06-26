package main

import (
	"context"
	"net"
	"os"
	"sync"

	"github.com/containerd/containerd/namespaces"
	"github.com/rs/zerolog/log"

	"github.com/r-hmuller/k8s-cr-daemon/config"
	"github.com/r-hmuller/k8s-cr-daemon/entity"
	pb "github.com/r-hmuller/k8s-cr-daemon/protos"
	"github.com/r-hmuller/k8s-cr-daemon/snapshot"
	"google.golang.org/grpc"
)

type server struct {
	pb.UnimplementedSnapshotRPCServiceServer
}

var snapshotRequestChannel = make(chan entity.SnapshotRequest)

func (s *server) Create(_ context.Context, in *pb.CreateSnapshotRequest) (*pb.AckResponse, error) {
	if in.Namespace == "" || in.RegistryName == "" || in.ServiceName == "" {
		log.Warn().
			Str("namespace", in.Namespace).
			Str("service_name", in.ServiceName).
			Str("registry_name", in.RegistryName).
			Msg("Snapshot request rejected: missing required fields")
		return &pb.AckResponse{Response: false, Error: "Namespace, RegistryName and ServiceName are required"}, nil
	}

	log.Info().
		Str("namespace", in.Namespace).
		Str("service_name", in.ServiceName).
		Str("registry_name", in.RegistryName).
		Uint64("latest_request", in.LatestRequest).
		Msg("Snapshot request accepted, queuing for processing")

	snapshotRequestChannel <- entity.SnapshotRequest{
		Namespace:     in.Namespace,
		ServiceName:   in.ServiceName,
		RegistryName:  in.RegistryName,
		LatestRequest: in.LatestRequest}
	return &pb.AckResponse{Response: true, Error: ""}, nil
}

func main() {
	config.CheckConfig()

	namespace := "default"
	ctx := namespaces.WithNamespace(context.Background(), namespace)
	var wg sync.WaitGroup
	wg.Add(2)
	go listenGrpcServer()
	go snapshot.GenerateSnapshot(ctx, &wg, snapshotRequestChannel)
	wg.Wait()
}

func listenGrpcServer() {
	grpcPort := os.Getenv("CR_DAEMON_GRPC_PORT")
	if grpcPort == "" {
		grpcPort = ":50051"
	}

	lis, err := net.Listen("tcp", grpcPort)
	if err != nil {
		log.Fatal().Err(err).Msg("failed to listen")
	}

	grpcServer := grpc.NewServer()
	pb.RegisterSnapshotRPCServiceServer(grpcServer, &server{})
	log.Info().Msgf("gRPC server listening at %v", lis.Addr())
	if err := grpcServer.Serve(lis); err != nil {
		log.Fatal().Err(err).Msg("failed to serve")
	}
}
