# Using -u (unset variable) results in an error on CircleCI (/etc/bash.bashrc uses unset "PS1")
SHELL := /bin/bash -eo pipefail

# Image URL to use all building/pushing image targets
TAG ?= $(shell git describe --tags --abbrev=0 --match 'v[0-9].*[0-9].*[0-9]' 2>/dev/null )
IMAGE_REPOSITORY ?= banzaicloud/istio-operator
IMG ?= ${IMAGE_REPOSITORY}:$(TAG)
# Produce CRDs that work back to Kubernetes 1.11 (no version conversion)
CRD_OPTIONS = "crd:trivialVersions=true,maxDescLen=0,preserveUnknownFields=false,allowDangerousTypes=true"

include test/e2e/e2e-test.mk

TEST_RACE_DETECTOR ?= 0

RELEASE_TYPE ?= p
RELEASE_MSG ?= "istio operator release"
API_RELEASE_MSG ?= "istio operator api release"
STATIC_RELEASE_MSG ?= "istio operator static charts release"

REL_TAG = $(shell ./scripts/increment_version.sh -${RELEASE_TYPE} ${TAG})
API_REL_TAG ?= pkg/apis/${REL_TAG}
STATIC_REL_TAG ?= static/${REL_TAG}

GOLANGCI_VERSION = 1.31.0
LICENSEI_VERSION = 0.1.0
KUBEBUILDER_VERSION = 2.3.1
KUSTOMIZE_VERSION = 2.0.3
ISTIO_VERSION = 1.10.4

KUSTOMIZE_BASE = config/overlays/specific-manager-version

ifeq (${TEST_RACE_DETECTOR}, 1)
    TEST_GOARGS += -race
    TEST_CGO_ENABLED = 1
endif
TEST_CGO_ENABLED ?= 0

all: test manager

.PHONY: check
check: test lint shellcheck-makefile shellcheck check-diff ## Run tests and linters

bin/golangci-lint: bin/golangci-lint-${GOLANGCI_VERSION}
	@ln -sf golangci-lint-${GOLANGCI_VERSION} bin/golangci-lint
bin/golangci-lint-${GOLANGCI_VERSION}:
	@mkdir -p bin
	curl -sfL https://install.goreleaser.com/github.com/golangci/golangci-lint.sh | bash -s -- -b ./bin v${GOLANGCI_VERSION}
	@mv bin/golangci-lint $@

.PHONY: lint
lint: bin/golangci-lint ## Run linter
	@bin/golangci-lint run -v

bin/licensei: bin/licensei-${LICENSEI_VERSION}
	@ln -sf licensei-${LICENSEI_VERSION} bin/licensei
bin/licensei-${LICENSEI_VERSION}:
	@mkdir -p bin
	curl -sfL https://raw.githubusercontent.com/goph/licensei/master/install.sh | bash -s v${LICENSEI_VERSION}
	@mv bin/licensei $@

.PHONY: license-check
license-check: bin/licensei ## Run license check
	bin/licensei check
	./scripts/check-header.sh

.PHONY: license-cache
license-cache: bin/licensei ## Generate license cache
	bin/licensei cache

# Run tests
.PHONY: test
test: install-kubebuilder generate fmt vet manifests test-apis
	env CGO_ENABLED=${TEST_CGO_ENABLED} \
	    KUBEBUILDER_ASSETS="$${PWD}/bin/kubebuilder/bin" \
	    go test ${TEST_GOARGS} ./pkg/... ./cmd/... -coverprofile cover.out

test-apis:
	cd pkg/apis && \
	env CGO_ENABLED=${TEST_CGO_ENABLED} \
	    KUBEBUILDER_ASSETS="$${PWD}/../../bin/kubebuilder/bin" \
	    go test ${TEST_GOARGS} ./...

# Build manager binary
manager: generate fmt vet build

# Build manager binary
build:
	go build -o bin/manager -ldflags="-X github.com/banzaicloud/istio-operator/pkg/apis/istio/v1beta1.SupportedIstioVersion=${ISTIO_VERSION} -X github.com/banzaicloud/istio-operator/pkg/apis/istio/v1beta1.Version=${TAG}" github.com/banzaicloud/istio-operator/cmd/manager

# Run against the configured Kubernetes cluster in ~/.kube/config
run: generate fmt vet
	go run ./cmd/manager/main.go

# Install kustomize
install-kustomize:
	scripts/install_kustomize.sh ${KUSTOMIZE_VERSION}

# Install kubebuilder
install-kubebuilder:
	scripts/install_kubebuilder.sh ${KUBEBUILDER_VERSION}

.PHONY: vendor
vendor:
	go mod vendor

# Install CRDs into a cluster
install: manifests
	kubectl apply -f config/base/crds

# Deploy controller in the configured Kubernetes cluster in ~/.kube/config
deploy: install-kustomize
	bin/kustomize build config | kubectl apply -f -
	./scripts/image_patch.sh "${KUSTOMIZE_BASE}/manager_image_patch.yaml" ${IMG}
	bin/kustomize build $(KUSTOMIZE_BASE) | kubectl apply -f -

# Generate manifests e.g. CRD, RBAC etc.
manifests: download-deps
	bin/controller-gen $(CRD_OPTIONS) rbac:roleName=manager-role webhook paths="./..." output:rbac:artifacts:config=config/base/rbac output:crd:artifacts:config=config/base/crds
	cd pkg/apis && ../../bin/controller-gen $(CRD_OPTIONS) rbac:roleName=manager-role webhook paths="./..." output:rbac:artifacts:config=../../config/base/rbac output:crd:artifacts:config=../../config/base/crds
	rm deploy/charts/istio-operator/crds/* && cp config/base/crds/* deploy/charts/istio-operator/crds/
	scripts/label-crds.sh $(ISTIO_VERSION)

# Run go fmt against code
fmt:
	go fmt ./...

# Run go vet against code
vet:
	go vet ./...

download-deps:
	./scripts/download-deps.sh

# Generate code
generate: download-deps
	go generate ./pkg/... ./cmd/...
	bin/controller-gen object:headerFile="hack/boilerplate.go.txt" paths="./..."
	cd pkg/apis && ../../bin/controller-gen object:headerFile="../../hack/boilerplate.go.txt" paths="./..."
	./hack/update-codegen.sh
	go run static/generate.go

# Verify codegen
verify-codegen: download-deps
	./hack/verify-codegen.sh

# Build the docker image
docker-build: vendor
	docker build -f Dockerfile.dev . -t ${IMG}

# Push the docker image
docker-push:
	docker push ${IMG}

check_release:
	@echo "New tags (${REL_TAG}, ${API_REL_TAG} and ${STATIC_REL_TAG}) will be pushed to Github, and a new Docker image (${REL_TAG}) will be released. Are you sure? [y/N] " && read -r ans && [ "$${ans:-N}" = y ]

.PHONY: check-diff
check-diff:
	@git --no-pager diff --name-only --exit-code -- 'static/*' || (echo "Please commit any changes to the generated code" && false)

release: check_release
	git tag -a ${REL_TAG} -m ${RELEASE_MSG}
	git tag -a ${API_REL_TAG} -m ${API_RELEASE_MSG}
	git tag -a ${STATIC_REL_TAG} -m ${STATIC_RELEASE_MSG}
	git push origin ${REL_TAG} ${API_REL_TAG} ${STATIC_REL_TAG}

.PHONY: shellcheck-makefile
shellcheck-makefile: bin/shellcheck ## Check each makefile recipe using shellcheck
	@grep -h -E '^[a-zA-Z_-]+:' $(MAKEFILE_LIST) | cut -d: -f1 | while IFS= read -r target; do \
		echo "Checking make target: $$target"; \
		make -s "$$target" SHELL=scripts/shellcheck-makefile.sh || exit 1; \
	done

.PHONY: shellcheck
shellcheck: bin/shellcheck ## Check shell scripts
	bin/shellcheck scripts/*.sh hack/*.sh docs/federation/gateway/cluster-add/*.sh docs/federation/flat/*.sh

bin/shellcheck:
	scripts/install_shellcheck.sh
