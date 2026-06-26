package k8s

import (
	"encoding/json"
	"os/exec"
	"strings"
)

// resolveImageStorageID converte um digest/imageRef do kubelet em image ID do
// storage local do cri-o (formato esperado em rootfsImageRef no restore).
// Prefere um ID que tenha repoTags (imagem nomeada) pra que o cri-o consiga
// reportar uma referencia de imagem valida no container restaurado (kubelet
// status.Image); usa o primeiro ID encontrado como fallback.
func resolveImageStorageID(refs ...string) string {
	fallback := ""
	for _, ref := range refs {
		if ref == "" {
			continue
		}
		ref = strings.TrimPrefix(ref, "docker-pullable://")
		out, err := exec.Command("crictl", "inspecti", "-o", "json", ref).Output()
		if err != nil {
			continue
		}
		var info struct {
			Status struct {
				ID       string   `json:"id"`
				RepoTags []string `json:"repoTags"`
			} `json:"status"`
		}
		if err := json.Unmarshal(out, &info); err != nil {
			continue
		}
		if info.Status.ID == "" {
			continue
		}
		if len(info.Status.RepoTags) > 0 {
			return info.Status.ID
		}
		if fallback == "" {
			fallback = info.Status.ID
		}
	}
	return fallback
}
