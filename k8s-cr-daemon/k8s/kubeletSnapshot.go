package k8s

type KubeletSnapshot struct {
	Namespace        string
	PodName          string
	ContainerName    string
	ServiceName      string
	ContainerImage   string
	ContainerImageID string
}
