package entity

type SnapshotRequest struct {
	Namespace     string
	ServiceName   string
	RegistryName  string
	LatestRequest uint64
}
