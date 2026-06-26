package k8s

import (
	"archive/tar"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/r-hmuller/k8s-cr-daemon/entity"

	v1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"

	"github.com/r-hmuller/k8s-cr-daemon/config"
	"github.com/rs/zerolog/log"
)

type SnapshotResponse struct {
	Items []string `json:"items"`
}

func GetPodByName(ctx context.Context, snapshotRequest entity.SnapshotRequest) (KubeletSnapshot, error) {
	pods, err := getPods(ctx, snapshotRequest.Namespace)
	if err != nil {
		return KubeletSnapshot{}, err
	}
	for _, pod := range pods {
		if strings.Contains(pod.Name, snapshotRequest.ServiceName) {
			containerName := pod.Spec.Containers[0].Name
			containerImage := pod.Spec.Containers[0].Image
			containerImageID := ""
			for _, cs := range pod.Status.ContainerStatuses {
				if cs.Name == containerName {
					if cs.Image != "" {
						containerImage = cs.Image
					}
					containerImageID = strings.TrimPrefix(cs.ImageID, "docker-pullable://")
					if idx := strings.LastIndex(containerImageID, "@"); idx >= 0 {
						containerImageID = containerImageID[idx+1:]
					}
					if id := resolveImageStorageID(cs.Image, cs.ImageID, containerImageID); id != "" {
						containerImageID = id
					}
					// Garante um repoTag estável na imagem-base (alvo do rootfsImageRef)
					// e a pina no storage até o restore. Sem isso, o push do checkpoint
					// pra :latest rouba o único nome da base → no restore o cri-o não
					// resolve someNameOfTheImage → ContainerStatus.Image vazio → pod
					// NotReady. buildah tag é só metadado (compartilha containers/storage
					// com o cri-o), não mexe em layer.
					if containerImageID != "" {
						if out, terr := exec.Command("buildah", "tag", containerImageID, "localhost/kv-test-base:restore").CombinedOutput(); terr != nil {
							log.Warn().Err(terr).Str("id", containerImageID).Str("output", string(out)).Msg("Falha ao taguear imagem-base p/ restore (não-fatal)")
						} else {
							log.Info().Str("id", containerImageID).Msg("Imagem-base tagueada p/ restore: localhost/kv-test-base:restore")
						}
					}
					break
				}
			}
			return KubeletSnapshot{
				Namespace:        pod.Namespace,
				PodName:          pod.Name,
				ContainerName:    containerName,
				ServiceName:      snapshotRequest.ServiceName,
				ContainerImage:   containerImage,
				ContainerImageID: containerImageID,
			}, nil
		}
	}
	return KubeletSnapshot{}, fmt.Errorf("pod %s not found", snapshotRequest.ServiceName)
}

func getPods(ctx context.Context, namespace string) ([]v1.Pod, error) {
	kubeconfig := os.Getenv("CR_DAEMON_KUBECONFIG_PATH")
	if kubeconfig == "" {
		kubeconfig = os.Getenv("CR_DAEMON_HOME") + "/.kube/configFromFlags"
	}

	_ = os.Getenv("CR_DAEMON_K8S_IP")
	// use the current context in kubeconfig
	configFromFlags, err := clientcmd.BuildConfigFromFlags("", kubeconfig)
	if err != nil {
		return nil, err
	}

	clientset, err := kubernetes.NewForConfig(configFromFlags)
	if err != nil {
		return nil, err
	}
	pods, err := clientset.CoreV1().Pods(namespace).List(ctx, metav1.ListOptions{})
	if err != nil {
		return nil, fmt.Errorf("failed to list pods in namespace %s: %w", namespace, err)
	}

	return pods.Items, nil
}

func GenerateKubeletSnapshot(_ context.Context, data KubeletSnapshot) (string, error) {
	kubeletApi := os.Getenv("CR_DAEMON_KUBELET_API")
	url := fmt.Sprintf("https://%s/checkpoint/%s/%s/%s", kubeletApi, data.Namespace, data.PodName, data.ContainerName)

	log.Info().
		Str("namespace", data.Namespace).
		Str("pod", data.PodName).
		Str("container", data.ContainerName).
		Msg("Initiating kubelet checkpoint request")

	kubeletCert := config.GetKubeletCertificate()
	clientTLSCert, err := tls.LoadX509KeyPair(kubeletCert.Cert, kubeletCert.Key)
	if err != nil {
		log.Error().Err(err).
			Str("namespace", data.Namespace).
			Str("pod", data.PodName).
			Msg("Failed to load client TLS certificate")
		return "", fmt.Errorf("failed to load client TLS cert: %w", err)
	}

	certPool, err := x509.SystemCertPool()
	if err != nil {
		log.Error().Err(err).
			Str("namespace", data.Namespace).
			Str("pod", data.PodName).
			Msg("Failed to load system cert pool")
		return "", fmt.Errorf("failed to load system cert pool: %w", err)
	}

	caCertPEM, err := os.ReadFile(kubeletCert.CA)
	if err != nil {
		log.Error().Err(err).
			Str("namespace", data.Namespace).
			Str("pod", data.PodName).
			Msg("Failed to read CA certificate")
		return "", fmt.Errorf("failed to read CA cert: %w", err)
	}
	if ok := certPool.AppendCertsFromPEM(caCertPEM); !ok {
		log.Error().
			Str("namespace", data.Namespace).
			Str("pod", data.PodName).
			Msg("Failed to append CA cert to pool")
		return "", fmt.Errorf("failed to append CA cert to pool")
	}

	tlsConfig := &tls.Config{
		RootCAs:            certPool,
		Certificates:       []tls.Certificate{clientTLSCert},
		InsecureSkipVerify: true,
	}
	tr := &http.Transport{
		TLSClientConfig: tlsConfig,
	}
	client := &http.Client{Transport: tr}
	resp, err := client.Post(url, "application/json", nil)
	if err != nil {
		log.Error().Err(err).
			Str("namespace", data.Namespace).
			Str("pod", data.PodName).
			Str("url", url).
			Msg("Failed to send checkpoint request to kubelet")
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, err := io.ReadAll(resp.Body)
		if err != nil {
			log.Error().Err(err).Msg("Failed to read response body")
		}
		log.Error().
			Int("status_code", resp.StatusCode).
			Str("namespace", data.Namespace).
			Str("pod", data.PodName).
			Str("response_body", string(body)).
			Msg("Kubelet checkpoint request failed")
		return "", fmt.Errorf("kubelet checkpoint failed with status %d", resp.StatusCode)
	}

	snapshotResponse := &SnapshotResponse{}
	json.NewDecoder(resp.Body).Decode(snapshotResponse)

	log.Info().
		Str("namespace", data.Namespace).
		Str("pod", data.PodName).
		Str("snapshot_file", snapshotResponse.Items[0]).
		Msg("Kubelet checkpoint created successfully")

	return snapshotResponse.Items[0], nil
}

func injectImageNameIntoCheckpoint(checkpointPath, imageName, imageID string) error {
	origFile, err := os.Open(checkpointPath)
	if err != nil {
		return fmt.Errorf("failed to open checkpoint: %w", err)
	}

	dir := filepath.Dir(checkpointPath)
	tmpFile, err := os.CreateTemp(dir, "checkpoint-modified-*")
	if err != nil {
		origFile.Close()
		return fmt.Errorf("failed to create temp file: %w", err)
	}
	tmpPath := tmpFile.Name()

	tr := tar.NewReader(origFile)
	tw := tar.NewWriter(tmpFile)
	modified := false

	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			origFile.Close()
			tmpFile.Close()
			os.Remove(tmpPath)
			return fmt.Errorf("failed to read tar: %w", err)
		}

		name := strings.TrimPrefix(hdr.Name, "./")

		if name == "config.dump" {
			data, err := io.ReadAll(tr)
			if err != nil {
				origFile.Close()
				tmpFile.Close()
				os.Remove(tmpPath)
				return fmt.Errorf("failed to read config.dump: %w", err)
			}

			var cfg map[string]interface{}
			if err := json.Unmarshal(data, &cfg); err != nil {
				origFile.Close()
				tmpFile.Close()
				os.Remove(tmpPath)
				return fmt.Errorf("failed to parse config.dump: %w", err)
			}

			cfg["rootfsImage"] = imageName
			cfg["rootfsImageName"] = imageName
			if imageID != "" {
				cfg["rootfsImageRef"] = imageID
			}
			// Extra defensivo p/ compat com cri-o antigos que liam image.image
			// (ImageSpec) do config.dump p/ ContainerStatus.Image. No cri-o 1.32
			// isto NÃO basta (o status vem de someNameOfTheImage, resolvido do
			// rootfsImageRef); o fix real do pod-Ready é taguear a imagem-base no
			// GetPodByName. Mantido como no-op inócuo.
			cfg["image"] = map[string]interface{}{"image": imageName}

			modifiedData, err := json.Marshal(cfg)
			if err != nil {
				origFile.Close()
				tmpFile.Close()
				os.Remove(tmpPath)
				return fmt.Errorf("failed to serialize config.dump: %w", err)
			}

			hdr.Size = int64(len(modifiedData))
			if err := tw.WriteHeader(hdr); err != nil {
				origFile.Close()
				tmpFile.Close()
				os.Remove(tmpPath)
				return fmt.Errorf("failed to write tar header: %w", err)
			}
			if _, err := tw.Write(modifiedData); err != nil {
				origFile.Close()
				tmpFile.Close()
				os.Remove(tmpPath)
				return fmt.Errorf("failed to write config.dump: %w", err)
			}
			modified = true
		} else {
			if err := tw.WriteHeader(hdr); err != nil {
				origFile.Close()
				tmpFile.Close()
				os.Remove(tmpPath)
				return fmt.Errorf("failed to write tar header: %w", err)
			}
			if _, err := io.Copy(tw, tr); err != nil {
				origFile.Close()
				tmpFile.Close()
				os.Remove(tmpPath)
				return fmt.Errorf("failed to copy tar entry: %w", err)
			}
		}
	}

	if err := tw.Close(); err != nil {
		origFile.Close()
		tmpFile.Close()
		os.Remove(tmpPath)
		return fmt.Errorf("failed to close tar writer: %w", err)
	}

	origFile.Close()
	tmpFile.Close()

	if !modified {
		os.Remove(tmpPath)
		return fmt.Errorf("config.dump not found in checkpoint tar")
	}

	if err := os.Rename(tmpPath, checkpointPath); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("failed to replace checkpoint: %w", err)
	}

	return nil
}

func GenerateOCIImageFromSnapshotFile(ctx context.Context, snapshot string, data KubeletSnapshot) error {
	log.Info().
		Str("service", data.ServiceName).
		Str("snapshot_file", snapshot).
		Msg("Building OCI image from snapshot file")

	cmd := exec.Command("buildah", "from", "scratch")
	output, err := cmd.Output()
	if err != nil {
		log.Error().Err(err).Str("service", data.ServiceName).Msg("Failed to run buildah from scratch")
		return err
	}

	newcontainer := strings.TrimSuffix(string(output), "\n")

	if err := injectImageNameIntoCheckpoint(snapshot, data.ContainerImage, data.ContainerImageID); err != nil {
		log.Error().Err(err).Str("service", data.ServiceName).Msg("Failed to inject rootfsImageName into config.dump")
		return err
	}
	log.Info().Str("service", data.ServiceName).Str("container_image", data.ContainerImage).Msg("Injected rootfsImageName into config.dump")

	cmd = exec.Command("buildah", "add", newcontainer, snapshot)
	_, err = cmd.Output()
	if err != nil {
		log.Error().Err(err).Str("service", data.ServiceName).Msg("Failed to run buildah add")
		return err
	}

	imageName := data.ServiceName
	registryServer := os.Getenv("CR_DAEMON_PRIVATE_REGISTRY_URL")
	registryImage := fmt.Sprintf("%s/rodrigohmuller/%s:latest", registryServer, imageName)

	log.Info().
		Str("service", data.ServiceName).
		Str("container_name", data.ContainerName).
		Str("container_image", data.ContainerImage).
		Msg("Setting checkpoint annotations")

	cmd = exec.Command("buildah", "config",
		"--annotation=io.kubernetes.cri-o.annotations.checkpoint.name="+data.ContainerName,
		"--annotation=io.kubernetes.cri-o.annotations.checkpoint.image.name="+data.ContainerImage,
		newcontainer)
	_, err = cmd.Output()
	if err != nil {
		log.Error().Err(err).Str("service", data.ServiceName).Msg("Failed to run buildah config")
		return err
	}

	// OTIMIZAÇÃO (snapshot mais rápido): commit direto pro registry em vez de
	// commit-local + push separado. Elimina a materialização local da imagem
	// (~1GB) e a releitura no push. --disable-compression: registry é LAN local,
	// comprimir custa mais CPU do que economiza em rede. O commit p/ docker://
	// só retorna após o upload concluir -> preserva a invariante "responder
	// 'completed' apenas após o registry confirmar o snapshot".
	log.Info().
		Str("registry_image", registryImage).
		Msg("Committing image directly to registry")

	cmd = exec.Command("buildah", "commit", "--disable-compression", "--tls-verify=false", "--format", "oci", newcontainer, "docker://"+registryImage)
	if out, cerr := cmd.CombinedOutput(); cerr != nil {
		log.Error().Err(cerr).Str("service", data.ServiceName).Str("registry_image", registryImage).Str("output", string(out)).Msg("Failed to commit image to registry")
		return cerr
	}

	// Limpeza do working container (não-fatal: a imagem já está salva no registry).
	cmd = exec.Command("buildah", "rm", newcontainer)
	if _, rmErr := cmd.Output(); rmErr != nil {
		log.Warn().Err(rmErr).Str("service", data.ServiceName).Msg("buildah rm falhou (não-fatal)")
	}

	log.Info().
		Str("service", data.ServiceName).
		Str("registry_image", registryImage).
		Msg("Image pushed to registry successfully")

	return nil
}
