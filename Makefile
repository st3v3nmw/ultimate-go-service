# Check to see if we can use ash, in Alpine images, or default to BASH.
SHELL_PATH = /bin/ash
SHELL = $(if $(wildcard $(SHELL_PATH)),/bin/ash,/bin/bash)

run:
	go run apis/services/sales/main.go | go run apis/tooling/logfmt/main.go

help:
	go run apis/services/sales/main.go --help

version:
	go run apis/services/sales/main.go --version

curl-live:
	curl -il -X GET http://localhost:3000/liveness

curl-ready:
	curl -il -X GET http://localhost:3000/readiness

curl-error:
	curl -il -X GET http://localhost:3000/testerror

# ==============================================================================
# Define dependencies

GOLANG          := golang:1.22
ALPINE          := alpine:3.20
KIND            := kindest/node:v1.30.0
POSTGRES        := postgres:16.3
GRAFANA         := grafana/grafana:10.4.0
PROMETHEUS      := prom/prometheus:v2.53.0
TEMPO           := grafana/tempo:2.5.0
LOKI            := grafana/loki:3.0.0
PROMTAIL        := grafana/promtail:3.0.0

KIND_CLUSTER    := ardan-starter-cluster
NAMESPACE       := sales-system
SALES_APP       := sales
AUTH_APP        := auth
BASE_IMAGE_NAME := localhost/ardanlabs
VERSION         := 0.0.1
SALES_IMAGE     := $(BASE_IMAGE_NAME)/$(SALES_APP):$(VERSION)
METRICS_IMAGE   := $(BASE_IMAGE_NAME)/metrics:$(VERSION)
AUTH_IMAGE      := $(BASE_IMAGE_NAME)/$(AUTH_APP):$(VERSION)

# ==============================================================================
# Building containers

build: sales

sales:
	docker build \
		-f zarf/docker/dockerfile.sales \
		-t $(SALES_IMAGE) \
		--build-arg BUILD_REF=$(VERSION) \
		--build-arg BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ") \
		.

# ==============================================================================
# Running from within k8s/kind

dev-up:
	kind create cluster \
		--image $(KIND) \
		--name $(KIND_CLUSTER) \
		--config zarf/k8s/dev/kind-config.yaml

	kubectl wait --timeout=120s --namespace=local-path-storage --for=condition=Available deployment/local-path-provisioner

	kind load docker-image $(POSTGRES) --name $(KIND_CLUSTER) & \
	kind load docker-image $(GRAFANA) --name $(KIND_CLUSTER) & \
	kind load docker-image $(PROMETHEUS) --name $(KIND_CLUSTER) & \
	kind load docker-image $(TEMPO) --name $(KIND_CLUSTER) & \
	kind load docker-image $(LOKI) --name $(KIND_CLUSTER) & \
	kind load docker-image $(PROMTAIL) --name $(KIND_CLUSTER) & \
	wait;

dev-down:
	kind delete cluster --name $(KIND_CLUSTER)

dev-status-all:
	kubectl get nodes -o wide
	kubectl get svc -o wide
	kubectl get pods -o wide --watch --all-namespaces

dev-status:
	watch -n 2 kubectl get pods --all-namespaces

# ------------------------------------------------------------------------------

dev-load:
	kind load docker-image $(SALES_IMAGE) --name $(KIND_CLUSTER)

dev-apply:
	kustomize build zarf/k8s/dev/sales | kubectl apply -f -
	kubectl wait pods --namespace=$(NAMESPACE) --selector app=$(SALES_APP) --timeout=120s --for=condition=Ready

dev-restart:
	kubectl rollout restart deployment $(SALES_APP) --namespace=$(NAMESPACE)

dev-update: build dev-load dev-restart

dev-update-apply: build dev-load dev-apply

dev-logs:
	kubectl logs --namespace=$(NAMESPACE) -l app=$(SALES_APP) --all-containers=true -f --tail=100 --max-log-requests=6 | go run apis/tooling/logfmt/main.go -service=$(SALES_APP)

# ------------------------------------------------------------------------------

dev-describe-deployment:
	kubectl describe deployment --namespace=$(NAMESPACE) $(SALES_APP)

dev-describe-sales:
	kubectl describe pod --namespace=$(NAMESPACE) -l app=$(SALES_APP)

# ==============================================================================
# Metrics and Tracing

metrics-view:
	expvarmon -ports="localhost:3010" -vars="build,requests,goroutines,errors,panics,mem:memstats.HeapAlloc,mem:memstats.HeapSys,mem:memstats.Sys"

statsviz:
	open http://localhost:3010/debug/statsviz

# ==============================================================================
# modules support

tidy:
	go mod tidy
	go mod vendor
