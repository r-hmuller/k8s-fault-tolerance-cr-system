package config

import (
	"os"
	"strconv"
	"sync"
)

var SnapshotLock = &sync.Mutex{}
var IsSnapshotBeingTaken = false

// VerifyEnvVars Env vars:
// - APPLICATION_URL: Full application URL, with port
// - INTERCEPTOR_PORT: Port to listen to
// - HEARTBEAT_ENABLED: Enable or disable the heartbeat
// - CHECKPOINT_ENABLED: Enable or disable the checkpoint
func VerifyEnvVars() {
	applicationUrl, ok := os.LookupEnv("APPLICATION_URL")
	if !ok {
		panic("Couldn't find the APPLICATION_URL variable")
	}

	if applicationUrl == "" {
		panic("APPLICATION_URL can't be empty")
	}

	interceptorPort, ok := os.LookupEnv("INTERCEPTOR_PORT")

	if !ok {
		panic("Couldn't find the INTERCEPTOR_PORT variable")
	}

	if interceptorPort == "" {
		panic("INTERCEPTOR_PORT can't be empty")
	}

	_, err := strconv.Atoi(interceptorPort)
	if err != nil {
		panic("INTERCEPTOR_PORT must be a number")
	}

	heartBeatEnabled, ok := os.LookupEnv("HEARTBEAT_ENABLED")
	if !ok {
		panic("Couldn't find the HEARTBEAT_ENABLED variable")
	}

	if _, err := strconv.ParseBool(heartBeatEnabled); err != nil {
		panic("HEARTBEAT_ENABLED must be a boolean")
	}

	checkpointEnabled, ok := os.LookupEnv("CHECKPOINT_ENABLED")
	if !ok {
		panic("Couldn't find the CHECKPOINT_ENABLED variable")
	}

	if _, err := strconv.ParseBool(checkpointEnabled); err != nil {
		panic("CHECKPOINT_ENABLED must be a boolean")
	}

	nameSpace, ok := os.LookupEnv("NAMESPACE")
	if !ok {
		panic("Couldn't find the NAMESPACE variable")
	}
	if nameSpace == "" {
		panic("NAMESPACE can't be empty")
	}

	serviceName, ok := os.LookupEnv("SERVICE_NAME")
	if !ok {
		panic("Couldn't find the SERVICE_NAME variable")
	}
	if serviceName == "" {
		panic("SERVICE_NAME can't be empty")
	}

	registryName, ok := os.LookupEnv("REGISTRY_NAME")
	if !ok {
		panic("Couldn't find the REGISTRY_NAME variable")
	}
	if registryName == "" {
		panic("REGISTRY_NAME can't be empty")
	}

	heartBeathPath, ok := os.LookupEnv("HEARTBEAT_PATH")
	if !ok {
		panic("Couldn't find the HEARTBEAT_PATH variable")
	}
	if heartBeathPath == "" {
		panic("HEARTBEAT_PATH can't be empty")
	}

	daemonGrpcUrl, ok := os.LookupEnv("DAEMON_GRPC_URL")
	if !ok {
		panic("Couldn't find the DAEMON_GRPC_URL variable")
	}
	if daemonGrpcUrl == "" {
		panic("DAEMON_GRPC_URL can't be empty")
	}

	selfGrpcUrl, ok := os.LookupEnv("GRPC_URL")
	if !ok {
		panic("Couldn't find the GRPC_URL variable")
	}
	if selfGrpcUrl == "" {
		panic("GRPC_URL can't be empty")
	}

	checkpointInterval, ok := os.LookupEnv("CHECKPOINT_INTERVAL")
	if !ok {
		panic("Couldn't find the CHECKPOINT_INTERVAL variable")
	}
	if checkpointInterval == "" {
		panic("CHECKPOINT_INTERVAL can't be empty")
	}
	_, err = strconv.Atoi(checkpointInterval)
	if err != nil {
		panic("CHECKPOINT_INTERVAL must be a number")
	}
}

func GetApplicationURL() string {
	return os.Getenv("APPLICATION_URL")
}

func GetInterceptorPort() string {
	interceptorPort := os.Getenv("INTERCEPTOR_PORT")
	if interceptorPort[0] != ':' {
		interceptorPort = ":" + interceptorPort
	}
	return interceptorPort
}

func GetHeartBeatPath() string {
	return os.Getenv("HEARTBEAT_PATH")
}

func GetNamespace() string {
	return os.Getenv("NAMESPACE")
}

func GetServiceName() string {
	return os.Getenv("SERVICE_NAME")
}

func GetRegistryName() string {
	return os.Getenv("REGISTRY_NAME")
}

func GetHeartBeatEnabled() bool {
	heartBeatEnabled, err := strconv.ParseBool(os.Getenv("HEARTBEAT_ENABLED"))
	if err != nil {
		panic("HEARTBEAT_ENABLED must be a boolean")
	}
	return heartBeatEnabled
}

func GetCheckpointEnabled() bool {
	checkpointEnabled, err := strconv.ParseBool(os.Getenv("CHECKPOINT_ENABLED"))
	if err != nil {
		panic("CHECKPOINT_ENABLED must be a boolean")
	}
	return checkpointEnabled
}

func GetEnableTrace() bool {
	enableTrace, err := strconv.ParseBool(os.Getenv("ENABLE_TRACE"))
	if err != nil {
		return false
	}
	return enableTrace
}

func GetDaemonGrpcUrl() string {
	return os.Getenv("DAEMON_GRPC_URL")
}

func GetSelfGrpcUrl() string {
	return os.Getenv("GRPC_URL")
}

func GetDirectApplicationURL() string {
	return os.Getenv("DIRECT_APPLICATION_URL")
}

func GetCheckpointInterval() int {
	checkpointInterval, err := strconv.Atoi(os.Getenv("CHECKPOINT_INTERVAL"))
	if err != nil {
		panic("CHECKPOINT_INTERVAL must be a number")
	}
	return checkpointInterval
}

// GetSnapshotDrainTimeout retorna o tempo (segundos) que o snapshot espera as
// requisicoes em voo drenarem antes de prosseguir. Env SNAPSHOT_DRAIN_TIMEOUT;
// default 30 se ausente/invalido.
func GetSnapshotDrainTimeout() int {
	v := os.Getenv("SNAPSHOT_DRAIN_TIMEOUT")
	if v == "" {
		return 30
	}
	n, err := strconv.Atoi(v)
	if err != nil || n <= 0 {
		return 30
	}
	return n
}
