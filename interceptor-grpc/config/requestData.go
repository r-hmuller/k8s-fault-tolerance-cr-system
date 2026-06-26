package config

import "net/http"

// RequestData is a self-contained copy of an HTTP request. The live
// *http.Request and http.ResponseWriter are only valid while their handler
// is running, so anything that outlives the handler (recovery queue,
// reprocess buffer) must hold this copy instead.
type RequestData struct {
	Method string
	Path   string
	Query  string
	Header http.Header
	Body   []byte
}

// Result is the outcome of forwarding a request to the application,
// delivered back to the waiting handler through a channel.
type Result struct {
	Status int
	Body   []byte
}
