package config

import (
	"log"
	"os"
)

type KubeletCertificate struct {
	Cert string
	Key  string
	CA   string
}

func CheckConfig() {
	if os.Getenv("CR_DAEMON_KUBECONFIG_PATH") == "" {
		log.Fatalf("KUBECONFIG is not set")
	}
	if os.Getenv("CR_DAEMON_K8S_IP") == "" {
		log.Fatalf("K8S_IP is not set")
	}
	if os.Getenv("CR_DAEMON_KUBELET_API") == "" {
		log.Fatalf("KUBELET_API is not set")
	}
	if os.Getenv("CR_DAEMON_GRPC_PORT") == "" {
		log.Fatalf("GRPC_PORT is not set")
	}
	if os.Getenv("CR_DAEMON_KUBELET_CERT") == "" {
		log.Fatalf("KUBELET_CERT is not set")
	}
	if os.Getenv("CR_DAEMON_KUBELET_KEY") == "" {
		log.Fatalf("KUBELET_KEY is not set")
	}
	if os.Getenv("CR_DAEMON_KUBELET_CA") == "" {
		log.Fatalf("KUBELET_CA is not set")
	}
	if os.Getenv("CR_DAEMON_PRIVATE_REGISTRY_URL") == "" {
		log.Fatalf("PRIVATE_REGISTRY_URL is not set")
	}
	if os.Getenv("CR_DAEMON_REPLY_TARGET") == "" {
		log.Fatalf("REPLY_TARGET is not set")
	}
}

func SendReplyMessage() bool {
	val := os.Getenv("SEND_REPLY_MESSAGE")
	return val != "false"
}

func GetKubeletCertificate() *KubeletCertificate {
	return &KubeletCertificate{
		Cert: os.Getenv("CR_DAEMON_KUBELET_CERT"),
		Key:  os.Getenv("CR_DAEMON_KUBELET_KEY"),
		CA:   os.Getenv("CR_DAEMON_KUBELET_CA"),
	}
}
