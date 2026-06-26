GO_BIN := $(shell go env GOBIN)
ifeq ($(GO_BIN),)
  GO_BIN := $(shell go env GOPATH)/bin
endif

.PHONY: generate_grpc_code ensure_go_plugins

ensure_go_plugins:
	@echo "Instalando protoc-gen-go e protoc-gen-go-grpc..."
	@GO111MODULE=on go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
	@GO111MODULE=on go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest

generate_grpc_code: ensure_go_plugins
	PATH="$(GO_BIN):$$PATH" protoc \
	  --go_out=. --go_opt=paths=source_relative \
	  --go-grpc_out=. --go-grpc_opt=paths=source_relative \
	  protos/request.proto