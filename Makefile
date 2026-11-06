# Image URL to use all building/pushing image targets
IMG ?= ghcr.io/cloudoperators/greenhouse:dev-$(USER)
IMG_LICENSE_EYE ?= ghcr.io/apache/skywalking-eyes/license-eye

MANIFESTS_PATH=$(CURDIR)/charts/manager
CRD_MANIFESTS_PATH=$(MANIFESTS_PATH)/crds
TEMPLATES_MANIFESTS_PATH=$(MANIFESTS_PATH)/templates
WEBHOOK_MANIFESTS_PATH=$(TEMPLATES_MANIFESTS_PATH)/webhook/webhooks.yaml

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# Setting SHELL to bash allows bash commands to be executed by recipes.
# This is a requirement for 'setup-envtest.sh' in the test target.
# Options are set to exit when a recipe line exits non-zero or a piped command fails.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

## Location to install dependencies an GO binaries
LOCALBIN ?= $(shell pwd)/bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)

## Auto Detect Platform
UNAME_P := $(shell uname -p)
PLATFORM :=
ifeq ($(UNAME_P),x86_64)
	PLATFORM = linux/amd64
endif
ifneq ($(filter arm%,$(UNAME_P)),)
	PLATFORM = linux/arm64
endif

CLI ?= $(LOCALBIN)/greenhousectl

.PHONY: all
all: build

##@ General

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Development

.PHONY: generate-all
generate-all: generate manifests generate-documentation generate-types license ## Generate code, manifests and documentation.

.PHONY: install
install: kustomize
	$(KUSTOMIZE) build $(CRD_MANIFESTS_PATH) | kubectl apply -f -
	kubectl apply -f $(WEBHOOK_MANIFESTS_PATH)
## Generate manifests for CRD, RBAC, Webhook and helmify the files
## CRD manifests are generated in hack/crd/bases
## Patches for CRD conversion webhooks need to be created under hack/crd/patches
## filename should be in the format webhook.*<group>*.*<kind>*.yaml"
.PHONY: manifests
manifests: controller-gen ## Generate WebhookConfiguration, ClusterRole and CustomResourceDefinition objects.
	$(CONTROLLER_GEN) crd paths="./api/..." output:crd:artifacts:config=hack/crd/bases
	GOBIN=$(LOCALBIN) go run ./hack/generate.go --crd-dir="./hack/crd" --charts-crd-dir=$(CRD_MANIFESTS_PATH)
	rm -rf hack/crd/bases

	$(CONTROLLER_GEN) rbac:roleName=manager-role webhook paths="./internal/webhook/..." paths="./internal/controller/..." output:artifacts:config=$(TEMPLATES_MANIFESTS_PATH)
	hack/helmify $(TEMPLATES_MANIFESTS_PATH)

.PHONY: generate-open-api-spec
generate-open-api-spec: VERSION = main
generate-open-api-spec:
	hack/openapi-generator/generate-openapi-spec-from-crds $(CRD_MANIFESTS_PATH) $(VERSION) docs/reference/api

.PHONY: generate-types
generate-types: generate-open-api-spec## Generate typescript types from CRDs.
	hack/typescript/create-types $(CURDIR)/docs/reference/api/openapi.yaml $(CURDIR)/hack/typescript/metadata.yaml $(CURDIR)/types/typescript/

.PHONY: generate-alerts-doc
generate-alerts-doc: ## Regenerate docs/operations/playbooks/_index.md from charts/manager/alerts.
	go run ./hack/docs-generator/alerts

.PHONY: actiongenerate
actiongenerate: action-controllergen
	$(CONTROLLER_GEN_ACTION) object:headerFile="hack/boilerplate.go.txt" paths="./api/..."
	$(CONTROLLER_GEN_ACTION) object:headerFile="hack/boilerplate.go.txt" paths="./internal/dex/..."

.PHONY: generate
generate: controller-gen ## Generate code containing DeepCopy, DeepCopyInto, and DeepCopyObject method implementations.
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./api/..."
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./internal/dex/..."

# Default values
GEN_DOCS_API_DIR ?= "../greenhouse/api" ## -app-dir should be Canonical Path Format so absolute path doesn't work. That's why we don't use $(CURDIR) here.
GEN_DOCS_CONFIG ?= "$(CURDIR)/hack/docs-generator/config.json"
GEN_DOCS_TEMPLATE_DIR ?= "$(CURDIR)/hack/docs-generator/templates"
GEN_DOCS_OUT_FILE ?= "$(CURDIR)/docs/reference/api/index.html"
GEN_CRD_API_REFERENCE_DOCS := $(CURDIR)/hack/docs-generator/gen-crd-api-reference-docs # Define the path to the gen-crd-api-reference-docs binary
.PHONY: check-gen-crd-api-reference-docs
check-gen-crd-api-reference-docs:
	@if [ ! -f $(GEN_CRD_API_REFERENCE_DOCS) ]; then \
		echo "gen-crd-api-reference-docs not found, installing..."; \
		GOBIN=$(LOCALBIN) go install github.com/ahmetb/gen-crd-api-reference-docs@latest; \
	fi

GEN_DOCS ?= $(LOCALBIN)/gen-crd-api-reference-docs
.PHONY: generate-documentation
generate-documentation: check-gen-crd-api-reference-docs generate-alerts-doc
	$(GEN_DOCS) -api-dir=$(GEN_DOCS_API_DIR) -config=$(GEN_DOCS_CONFIG) -template-dir=$(GEN_DOCS_TEMPLATE_DIR) -out-file=$(GEN_DOCS_OUT_FILE)

.PHONY: test
test: manifests generate license envtest flux-crds ## Run tests.
	KUBEBUILDER_ASSETS="$(shell $(ENVTEST) use $(ENVTEST_K8S_VERSION) -p path)" go test ./... -coverprofile cover.out -v
	cd api; go test ./...


.PHONY: flux-crds
flux-crds: kustomize
	mkdir -p bin/flux
	$(KUSTOMIZE) build config/samples/flux/crds > bin/flux/crds.yaml

.PHONY: fmt
fmt: goimports
	GOBIN=$(LOCALBIN) go fmt ./...
	$(GOIMPORTS) -w -local github.com/cloudoperators/greenhouse .
	cd api; GOBIN=$(LOCALBIN) go fmt ./...

.PHONY: lint
lint: golint
	$(GOLINT) run -v --timeout 5m
	cd api; $(GOLINT) run -v --timeout 5m

.PHONY: check
check: fmt lint test

##@ Build CLI Locally
.PHONY: cli
cli: $(CLI)
$(CLI): $(LOCALBIN)
	test -s $(LOCALBIN)/greenhousectl || echo "Building Greenhouse CLI..." && make build-greenhousectl

##@ Build
.PHONY: action-build
action-build: build-greenhouse build-idproxy build-cors-proxy build-greenhousectl build-service-proxy build-authz

.PHONY: build
build: generate build-greenhouse build-idproxy build-cors-proxy build-greenhousectl build-service-proxy build-authz

build-%: GIT_BRANCH  = $(shell git rev-parse --abbrev-ref HEAD)
build-%: GIT_COMMIT  = $(shell git rev-parse --short HEAD)
build-%: GIT_STATE   = $(shell if git diff --quiet; then echo clean; else echo dirty; fi)
build-%: BUILD_DATE  = $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")
build-%:
	go build -ldflags "-s -w -X github.com/cloudoperators/greenhouse/internal/version.GitBranch=$(GIT_BRANCH) -X github.com/cloudoperators/greenhouse/internal/version.GitCommit=$(GIT_COMMIT) -X github.com/cloudoperators/greenhouse/internal/version.GitState=$(GIT_STATE) -X github.com/cloudoperators/greenhouse/internal/version.BuildDate=$(BUILD_DATE)" -o bin/$* ./cmd/$*/

.PHONY: run
run: manifests generate fmt vet ## Run a controller from your host.
	go run ./cmd/greenhouse/

.PHONY: docker-build
docker-build:
	docker build --platform ${PLATFORM} -t ${IMG} .

.PHONY: docker-push
docker-push: ## Push docker image with the manager.
	docker push ${IMG}

##@ Deployment

ifndef ignore-not-found
  ignore-not-found = false
endif

.PHONY: kustomize-build-crds
kustomize-build-crds: manifests kustomize
	$(KUSTOMIZE) build $(CRD_MANIFESTS_PATH)
	
##@ Build Dependencies

## Tool Binaries
KUSTOMIZE ?= $(LOCALBIN)/kustomize
CONTROLLER_GEN ?= $(LOCALBIN)/controller-gen
CONTROLLER_GEN_ACTION ?= $(LOCALBIN)/action-controller-gen
GOIMPORTS ?= $(LOCALBIN)/goimports
GOLINT ?= $(LOCALBIN)/golangci-lint
ENVTEST ?= $(LOCALBIN)/setup-envtest
ENVTEST_ACTION ?= $(LOCALBIN)/action-setup-envtest
HELMIFY ?= $(LOCALBIN)/helmify
HELM_DOCS ?= $(LOCALBIN)/helm-docs

## Tool Versions
KUSTOMIZE_VERSION ?= 5.8.1
CERT_MANAGER_VERSION ?= v1.20.1
METALLB_VERSION ?= v0.14.9
INGRESS_NGINX_VERSION ?= 4.11.3
EXTERNAL_DNS_VERSION ?= 1.15.0
CONTROLLER_TOOLS_VERSION ?= 0.21.0
GOLINT_VERSION ?= 2.12.2
GINKGOLINTER_VERSION ?= 0.23.0
HELM_DOCS_VERSION ?= 1.14.2
# ENVTEST_K8S_VERSION refers to the version of kubebuilder assets to be downloaded by envtest binary.
ENVTEST_K8S_VERSION ?= 1.36.0

KUSTOMIZE_INSTALL_SCRIPT ?= "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh"
.PHONY: kustomize
kustomize: $(KUSTOMIZE) ## Download kustomize locally if necessary.
$(KUSTOMIZE): $(LOCALBIN)
	@if [ -z "$$GITHUB_TOKEN" ]; then \
		test -s $(LOCALBIN)/kustomize || curl -s $(KUSTOMIZE_INSTALL_SCRIPT) | bash -s -- $(subst v,,$(KUSTOMIZE_VERSION)) $(LOCALBIN); \
	else \
	  	echo "pulling kustomize from source"; \
		test -s $(LOCALBIN)/kustomize || curl -sH "Authorization: Bearer $$GITHUB_TOKEN" $(KUSTOMIZE_INSTALL_SCRIPT) | bash -s -- $(subst v,,$(KUSTOMIZE_VERSION)) $(LOCALBIN); \
	fi

.PHONY: action-controllergen
action-controllergen:: $(CONTROLLER_GEN_ACTION) ## Download controller-gen locally if necessary.
$(CONTROLLER_GEN_ACTION):: $(LOCALBIN)
	GOMODCACHE=$(shell pwd)/tmp GOPATH=$(shell pwd) go install -modcacherw sigs.k8s.io/controller-tools/cmd/controller-gen@v$(CONTROLLER_TOOLS_VERSION)
	GOMODCACHE=$(shell pwd)/tmp go clean -modcache
	rm -rf $(shell pwd)/pkg/sumdb/

.PHONY: controller-gen
controller-gen:: $(CONTROLLER_GEN) ## Download controller-gen locally if necessary.
$(CONTROLLER_GEN):: $(LOCALBIN)
	GOBIN=$(LOCALBIN) go install sigs.k8s.io/controller-tools/cmd/controller-gen@v$(CONTROLLER_TOOLS_VERSION)

.PHONY: action-envtest
action-envtest:: $(ENVTEST) ## Download envtest-setup locally if necessary.
$(ENVTEST_ACTION):: $(LOCALBIN)
	GOMODCACHE=$(shell pwd)/tmp GOPATH=$(shell pwd) go install -modcacherw sigs.k8s.io/controller-runtime/tools/setup-envtest@latest
	GOMODCACHE=$(shell pwd)/tmp go clean -modcache
	rm -rf $(shell pwd)/pkg/sumdb/

.PHONY: envtest
envtest:: $(ENVTEST) ## Download envtest-setup locally if necessary.
$(ENVTEST):: $(LOCALBIN)
	GOBIN=$(LOCALBIN) go install sigs.k8s.io/controller-runtime/tools/setup-envtest@latest

.PHONY: goimports
goimports: $(GOIMPORTS)
$(GOIMPORTS): $(LOCALBIN)
	GOBIN=$(LOCALBIN) go install golang.org/x/tools/cmd/goimports@latest

.PHONY: golint
golint: $(GOLINT)
$(GOLINT): $(LOCALBIN)
	GOBIN=$(LOCALBIN) go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v$(GOLINT_VERSION)
	GOBIN=$(LOCALBIN) go install github.com/nunnatsa/ginkgolinter/cmd/ginkgolinter@v$(GINKGOLINTER_VERSION)

.PHONY: helm-docs
helm-docs: $(HELM_DOCS) ## Download helm-docs locally if necessary.
$(HELM_DOCS): $(LOCALBIN)
	$(call go-install-tool,$(HELM_DOCS),github.com/norwoodj/helm-docs/cmd/helm-docs,v$(HELM_DOCS_VERSION))

.PHONY: authz-docs
authz-docs: helm-docs ## Generate README for charts/authz using helm-docs.
	$(HELM_DOCS) --chart-search-root charts/authz

# go-install-tool will 'go install' any package with custom target and name of binary, if it doesn't exist
# $1 - target path with name of binary
# $2 - package url which can be installed
# $3 - specific version of package
define go-install-tool
@[ -f "$(1)-$(3)" ] || { \
set -e; \
package=$(2)@$(3) ;\
echo "Downloading $${package}" ;\
rm -f $(1) || true ;\
GOBIN=$(LOCALBIN) go install $${package} ;\
mv $(1) $(1)-$(3) ;\
} ;\
ln -sf $(1)-$(3) $(1)
endef



.PHONY: serve-docs
serve-docs: manifests
ifeq (, $(shell which hugo))
	@echo "Hugo is not installed in your machine. Please install it to serve the documentation locally. Please refer to https://gohugo.io/installation/ for installation instructions."
else
	cd website && hugo server
endif

SCENARIO ?= cluster
ADMIN_CLUSTER ?= greenhouse-admin
REMOTE_CLUSTER ?= greenhouse-remote
EXECUTION_ENV ?= LOCAL
ADMIN_NAMESPACE ?= greenhouse
ADMIN_RELEASE ?= greenhouse
ADMIN_CHART_PATH ?= charts/manager
E2E_REPORT_PATH="$(shell pwd)/bin/$(SCENARIO)-e2e-report.json"
PLUGIN_DIR ?=
DEMO_ORG ?= demo
DEV_MODE ?= false
INTERNAL ?= -int
WITH_CONTROLLER ?= true
E2E_RESULT_DIR ?= $(shell pwd)/bin

# Include authz-related targets from hack/authz/authz.mk
include hack/authz/authz.mk

.PHONY: setup-install
setup-install: cli ## Set up a local install-test environment with ingress-nginx, metallb, external-dns, and CoreDNS. Run 'make dns-mac' once afterwards to configure macOS DNS.
	$(CLI) dev setup -f dev-env/install.config.yaml
	@echo ""
	@echo "API server: $$(kubectl config view --context=$(INSTALL_CONTEXT) --minify -o jsonpath='{.clusters[0].cluster.server}')"

INSTALL_CONTEXT ?= kind-greenhouse-install
INSTALL_DNS_DOMAIN ?= install.greenhouse
INSTALL_ORG ?= greenhouse
MANAGER_CHART_VERSION ?= 0.16.2

.PHONY: install-greenhouse
install-greenhouse: ## Install the Greenhouse manager chart (from OCI) into the greenhouse-install cluster, using a locally-built manager image.
	docker build -t greenhouse/manager:local .
	kind load docker-image greenhouse/manager:local --name greenhouse-install
	helm upgrade --install greenhouse oci://ghcr.io/fabian-albrecht/greenhouse-helm/charts/manager \
		--version $(MANAGER_CHART_VERSION) \
		--kube-context $(INSTALL_CONTEXT) \
		--namespace greenhouse --create-namespace \
		--values dev-env/install.values.yaml \
		--wait --timeout 5m

.PHONY: install-catalog
install-catalog: ## Install the greenhouse system org, greenhouse-extensions Catalog, and base Plugins (ingress-nginx, external-dns, idproxy, authz, dashboard (bundles cors-proxy), gateway-discovery-server) into the greenhouse-install cluster.
	kubectl apply --context $(INSTALL_CONTEXT) -f config/samples/organization/greenhouse-install-oidc-secret.yaml
	kubectl apply --context $(INSTALL_CONTEXT) -f config/samples/organization/greenhouse-install.yaml
	kubectl wait organization greenhouse --context $(INSTALL_CONTEXT) --for=jsonpath='{.status.statusConditions.conditions[?(@.type=="Ready")].status}'=True --timeout=60s
	kubectl apply --context $(INSTALL_CONTEXT) -f config/samples/catalog/greenhouse-extensions-catalog.yaml
	kubectl wait catalog greenhouse-extensions --context $(INSTALL_CONTEXT) -n greenhouse --for=jsonpath='{.status.statusConditions.conditions[?(@.type=="Ready")].status}'=True --timeout=180s
	kubectl wait plugindefinition ingress-nginx --context $(INSTALL_CONTEXT) -n greenhouse --for=jsonpath='{.status.statusConditions.conditions[?(@.type=="Ready")].status}'=True --timeout=120s
	kubectl wait plugindefinition external-dns --context $(INSTALL_CONTEXT) -n greenhouse --for=jsonpath='{.status.statusConditions.conditions[?(@.type=="Ready")].status}'=True --timeout=120s
	kubectl wait plugindefinition k8s-gateway-api --context $(INSTALL_CONTEXT) -n greenhouse --for=jsonpath='{.status.statusConditions.conditions[?(@.type=="Ready")].status}'=True --timeout=120s
	kubectl wait plugindefinition kgateway-crds --context $(INSTALL_CONTEXT) -n greenhouse --for=jsonpath='{.status.statusConditions.conditions[?(@.type=="Ready")].status}'=True --timeout=120s
	kubectl wait plugindefinition kgateway --context $(INSTALL_CONTEXT) -n greenhouse --for=jsonpath='{.status.statusConditions.conditions[?(@.type=="Ready")].status}'=True --timeout=120s
	kubectl apply --context $(INSTALL_CONTEXT) -f config/samples/plugin/ingress-nginx.yaml
	kubectl apply --context $(INSTALL_CONTEXT) -f config/samples/plugin/external-dns.yaml
	# Gateway API + kgateway must be installed (in order) before the central Gateway
	# and the gateway-discovery-server can reconcile. Install CRDs first, then the
	# kgateway controller (which creates the "kgateway" GatewayClass).
	kubectl apply --context $(INSTALL_CONTEXT) -f config/samples/plugin/k8s-gateway-api.yaml
	kubectl apply --context $(INSTALL_CONTEXT) -f config/samples/plugin/kgateway-crds.yaml
	kubectl wait plugin k8s-gateway-api --context $(INSTALL_CONTEXT) -n greenhouse --for=jsonpath='{.status.statusConditions.conditions[?(@.type=="Ready")].status}'=True --timeout=180s
	kubectl wait plugin kgateway-crds --context $(INSTALL_CONTEXT) -n greenhouse --for=jsonpath='{.status.statusConditions.conditions[?(@.type=="Ready")].status}'=True --timeout=180s
	kubectl apply --context $(INSTALL_CONTEXT) -f config/samples/plugin/kgateway.yaml
	kubectl wait plugin kgateway --context $(INSTALL_CONTEXT) -n greenhouse --for=jsonpath='{.status.statusConditions.conditions[?(@.type=="Ready")].status}'=True --timeout=300s
	kubectl apply --context $(INSTALL_CONTEXT) -f config/samples/clusterplugindefiniton/idproxy.yaml
	kubectl apply --context $(INSTALL_CONTEXT) -f config/samples/clusterplugindefiniton/dashboard.yaml
	kubectl apply --context $(INSTALL_CONTEXT) -f config/samples/clusterplugindefiniton/authz.yaml
	kubectl apply --context $(INSTALL_CONTEXT) -f config/samples/clusterplugindefiniton/gateway-discovery-server.yaml
	kubectl wait clusterplugindefinition idproxy --context $(INSTALL_CONTEXT) --for=jsonpath='{.status.statusConditions.conditions[?(@.type=="Ready")].status}'=True --timeout=120s
	kubectl wait clusterplugindefinition dashboard --context $(INSTALL_CONTEXT) --for=jsonpath='{.status.statusConditions.conditions[?(@.type=="Ready")].status}'=True --timeout=120s
	kubectl wait clusterplugindefinition authz --context $(INSTALL_CONTEXT) --for=jsonpath='{.status.statusConditions.conditions[?(@.type=="Ready")].status}'=True --timeout=120s
	kubectl wait clusterplugindefinition gateway-discovery-server --context $(INSTALL_CONTEXT) --for=jsonpath='{.status.statusConditions.conditions[?(@.type=="Ready")].status}'=True --timeout=120s
	kubectl apply --context $(INSTALL_CONTEXT) -f config/samples/plugin/idproxy.yaml
	kubectl apply --context $(INSTALL_CONTEXT) -f config/samples/plugin/dashboard.yaml
	kubectl apply --context $(INSTALL_CONTEXT) -f config/samples/plugin/authz.yaml
	kubectl apply --context $(INSTALL_CONTEXT) -f config/samples/plugin/gateway-discovery-server.yaml

.PHONY: configure-oidc-apiserver
configure-oidc-apiserver: ## (Local dev only) Configure the install cluster API server to trust idproxy as OIDC issuer.
	@kubectl get secret greenhouse-ca -n cert-manager --context $(INSTALL_CONTEXT) -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/greenhouse-ca.crt
	@yq eval --inplace '.jwt[0].issuer.url = "https://auth.$(INSTALL_DNS_DOMAIN)"' dev-env/oidc/authentication-config.yaml
	@yq eval --inplace '.jwt[0].issuer.audiences[0] = "$(INSTALL_ORG)"' dev-env/oidc/authentication-config.yaml
	@yq eval --inplace '.jwt[0].issuer.certificateAuthority = load_str("/tmp/greenhouse-ca.crt")' dev-env/oidc/authentication-config.yaml
	@rm -f /tmp/greenhouse-ca.crt
	@echo "Written dev-env/oidc/authentication-config.yaml — apiserver will hot-reload within seconds."

.PHONY: trust-ca
trust-ca: ## (Local dev only) Import the greenhouse CA cert into the macOS system keychain so all *.install.greenhouse endpoints are trusted.
	kubectl get secret greenhouse-ca -n cert-manager --context $(INSTALL_CONTEXT) -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/greenhouse-ca.crt
	-sudo security delete-certificate -c "greenhouse-install-ca" /Library/Keychains/System.keychain 2>/dev/null
	sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /tmp/greenhouse-ca.crt
	@rm -f /tmp/greenhouse-ca.crt
	@echo "CA cert imported — restart your browser to pick up the new trust."

.PHONY: configure-mac
configure-mac: dns-mac configure-oidc-apiserver trust-ca ## (Local dev only) Full Mac setup: DNS, API server OIDC config, import CA cert into macOS keychain.

.PHONY: teardown-install
teardown-install: ## Tear down the install-test environment (KinD cluster + Mac DNS config).
	-kind delete cluster --name greenhouse-install
	-rm -f $(LOCALBIN)/greenhouse-install.kubeconfig
	@echo "Cleaning up macOS DNS config..."
	-sudo rm -f /etc/resolver/install.greenhouse
	-rm -f $(shell brew --prefix)/etc/dnsmasq.d/install.greenhouse.conf
	-sudo brew services stop dnsmasq 2>/dev/null || brew services stop dnsmasq 2>/dev/null || true
	-ifconfig lo0 | grep -q 127.0.0.2 && sudo ifconfig lo0 -alias 127.0.0.2 || true
	-sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
	@echo "Removing greenhouse CA cert from macOS keychain..."
	-sudo security delete-certificate -c "greenhouse-install-ca" /Library/Keychains/System.keychain
	@echo "Done. Re-run 'make setup-install && make dns-mac' to start fresh."

.PHONY: setup
setup: setup-manager setup-dashboard setup-demo

.PHONY: setup-webhook-dev
setup-webhook-dev:
	WITH_CONTROLLER=false DEV_MODE=true make setup-manager
	
.PHONY: setup-controller-dev
setup-controller-dev:
	WITH_CONTROLLER=false make setup-manager

.PHONY: setup-manager
setup-manager: cli
	CONTROLLER_ENABLED=$(WITH_CONTROLLER) PLUGIN_PATH=$(PLUGIN_DIR) $(CLI) dev setup -f dev-env/dev.config.yaml d=$(DEV_MODE)

.PHONY: setup-dashboard
setup-dashboard: cli
	$(CLI) dev setup dashboard -f dev-env/ui.config.yaml

.PHONY: setup-demo
setup-demo: prepare-e2e samples
	kubectl config use-context kind-$(ADMIN_CLUSTER)
	kubectl create secret generic kind-$(REMOTE_CLUSTER) \
		--from-literal=kubeconfig="$$(cat ${PWD}/bin/$(REMOTE_CLUSTER)$(INTERNAL).kubeconfig)" \
		--namespace=$(DEMO_ORG) \
		--type="greenhouse.sap/kubeconfig" \
		--dry-run=client -o yaml | kubectl apply -f -

.PHONY: samples
samples: kustomize
	$(KUSTOMIZE) build config/samples/organization | kubectl --kubeconfig=$(shell pwd)/bin/$(ADMIN_CLUSTER).kubeconfig apply -f -
	while true; do \
		if kubectl get organizations $(DEMO_ORG) --kubeconfig=$(shell pwd)/bin/$(ADMIN_CLUSTER).kubeconfig -o json | \
			jq -e '.status.statusConditions.conditions[] | select(.type == "Ready") | select(.status == "True")' > /dev/null; then \
			echo "Organization is ready"; \
			exit 0; \
		fi; \
		sleep 5; \
	done

.PHONY: catalog
catalog: kustomize
	$(KUSTOMIZE) build config/samples/catalog | kubectl --kubeconfig=$(shell pwd)/bin/$(ADMIN_CLUSTER).kubeconfig apply -f -

.PHONY: setup-e2e
setup-e2e: cli
	CONTROLLER_ENABLED=$(WITH_CONTROLLER) $(CLI) dev setup -f e2e/config.yaml
	make prepare-e2e

.PHONY: clean-e2e
clean-e2e:
	kind delete cluster --name $(REMOTE_CLUSTER)
	kind delete cluster --name $(ADMIN_CLUSTER)
	rm -rf $(LOCALBIN)/*.kubeconfig

.PHONY: e2e
e2e:
	GOMEGA_DEFAULT_EVENTUALLY_TIMEOUT="5m" \
		go test -tags="$(SCENARIO)E2E" ${PWD}/e2e/$(SCENARIO) -mod=readonly -test.v -ginkgo.v --ginkgo.json-report=$(E2E_REPORT_PATH)

.PHONY: e2e-local
e2e-local: prepare-e2e
	GREENHOUSE_ADMIN_KUBECONFIG="$(E2E_RESULT_DIR)/$(ADMIN_CLUSTER).kubeconfig" \
    	GREENHOUSE_REMOTE_KUBECONFIG="$(E2E_RESULT_DIR)/$(REMOTE_CLUSTER).kubeconfig" \
    	GREENHOUSE_REMOTE_INT_KUBECONFIG="$(E2E_RESULT_DIR)/$(REMOTE_CLUSTER)-int.kubeconfig" \
    	CONTROLLER_LOGS_PATH="$(E2E_RESULT_DIR)/$(SCENARIO)-e2e-pod-logs.txt" \
    	EXECUTION_ENV=$(EXECUTION_ENV) \
		GOMEGA_DEFAULT_EVENTUALLY_TIMEOUT="2m" \
		go test -tags="$(SCENARIO)E2E" $(shell pwd)/e2e/$(SCENARIO) -test.v -ginkgo.v --ginkgo.json-report=$(E2E_REPORT_PATH)

.PHONY: prepare-e2e
prepare-e2e:
	kind get kubeconfig --name $(ADMIN_CLUSTER) > $(shell pwd)/bin/$(ADMIN_CLUSTER).kubeconfig
	kind get kubeconfig --name $(REMOTE_CLUSTER) > $(shell pwd)/bin/$(REMOTE_CLUSTER).kubeconfig
	kind get kubeconfig --name $(REMOTE_CLUSTER) --internal > ${PWD}/bin/$(REMOTE_CLUSTER)-int.kubeconfig

.PHONY: list-scenarios
list-scenarios:
	find $(shell pwd)/e2e -type f -name 'e2e_test.go' -exec dirname {} \; | xargs -n 1 basename | jq -R -s -c 'split("\n")[:-1]'

mockery:
	# will look into .mockery.yaml for configuration
	docker run -v $(shell pwd):/src -w /src vektra/mockery:3

.PHONY: cert-manager
cert-manager: kustomize
	helm repo add jetstack https://charts.jetstack.io
	# Gateway API cert-shim is on by default (>=1.15). ListenerSet support (alpha
	# in 1.20) needs BOTH the ListenerSets feature gate (--feature-gates, via the
	# top-level featureGates value) AND the --enable-gateway-api-listenerset flag
	# (via extraArgs) — so cert-manager issues TLS certs for Gateway API
	# ListenerSets annotated with cert-manager.io/cluster-issuer.
	helm upgrade --namespace cert-manager --version $(CERT_MANAGER_VERSION) --install cert-manager jetstack/cert-manager \
		--set crds.enabled=true \
		--set featureGates="ListenerSets=true" \
		--set "extraArgs={--enable-gateway-api,--enable-gateway-api-listenerset}" \
		--create-namespace --wait --timeout 3m
	kubectl apply --context $(INSTALL_CONTEXT) -f dev-env/selfsigned-issuer.yaml
	kubectl apply --context $(INSTALL_CONTEXT) -f dev-env/ca-issuer.yaml

.PHONY: flux
flux: kustomize
	-$(KUSTOMIZE) build config/samples/flux | kubectl apply -f -

.PHONY: license
license:
	docker run --rm -v $(shell pwd):/github/workspace $(IMG_LICENSE_EYE) -c .github/licenserc.yaml header fix

.PHONY: zot
zot:
	# kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -
	# helm repo add project-zot https://zotregistry.dev/helm-charts
	# helm repo update project-zot
	# helm upgrade --namespace flux-system --version $(ZOT_VERSION) --install zot project-zot/zot -f dev-env/zot.values.yaml --create-namespace
	bash hack/registry/setup.sh

.PHONY: metallb
metallb: ## Install metallb and configure an IP pool from the kind docker bridge subnet (172.18.0.200-210).
	helm repo add metallb https://metallb.github.io/metallb
	helm upgrade --install metallb metallb/metallb \
		--namespace metallb-system --create-namespace \
		--version $(METALLB_VERSION) \
		--wait --timeout 3m
	kubectl apply -f dev-env/metallb-pool.yaml

.PHONY: ingress-nginx
ingress-nginx: ## Install ingress-nginx as a LoadBalancer service (gets IP from metallb).
	helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
	helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
		--namespace ingress-nginx --create-namespace \
		--version $(INGRESS_NGINX_VERSION) \
		--set controller.service.type=LoadBalancer \
		--wait --timeout 3m

.PHONY: etcd-dns
etcd-dns: ## Deploy a single-node etcd (quay.io/coreos/etcd) for the CoreDNS etcd plugin (external-dns backend).
	kubectl apply -f dev-env/etcd-dns.yaml
	kubectl rollout status deployment/etcd-dns -n greenhouse --timeout=3m

.PHONY: coredns-ext
coredns-ext: ## Install a second CoreDNS instance serving install.greenhouse via the etcd plugin (NodePort 30053 → host port 5354).
	kubectl apply -f dev-env/coredns-ext.yaml
	kubectl rollout status deployment/coredns-ext -n greenhouse --timeout=3m
	@echo ""
	@echo "CoreDNS is reachable on 127.0.0.1:5354 (via KinD extraPortMapping)"
	@echo ""
	@echo "Add DNS resolver for install.greenhouse on your Mac:"
	@echo "  sudo mkdir -p /etc/resolver"
	@echo "  printf 'nameserver 127.0.0.1\\nport 5354\\n' | sudo tee /etc/resolver/install.greenhouse"

.PHONY: external-dns-local
external-dns-local: ## Install external-dns with the coredns provider (writes to etcd-dns).
	helm repo add external-dns https://kubernetes-sigs.github.io/external-dns
	helm upgrade --install external-dns external-dns/external-dns \
		--namespace greenhouse --create-namespace \
		--version $(EXTERNAL_DNS_VERSION) \
		--set provider.name=coredns \
		--set "env[0].name=ETCD_URLS" \
		--set "env[0].value=http://etcd-dns.greenhouse.svc.cluster.local:2379" \
		--set "coredns.etcdEndpoints=http://etcd-dns.greenhouse.svc.cluster.local:2379" \
		--set "domainFilters[0]=install.greenhouse" \
		--set txtOwnerId=greenhouse-install \
		--set policy=sync \
		--set interval=10s \
		--wait --timeout 3m

.PHONY: dns-mac
dns-mac: ## Configure *.install.greenhouse → 127.0.0.1 on macOS via dnsmasq on a loopback alias.
	brew install dnsmasq
	@printf 'address=/install.greenhouse/127.0.0.1\nlisten-address=127.0.0.2\nbind-interfaces\n' \
		> $(shell brew --prefix)/etc/dnsmasq.d/install.greenhouse.conf
	sudo ifconfig lo0 alias 127.0.0.2
	sudo brew services restart dnsmasq
	sudo mkdir -p /etc/resolver
	@printf 'nameserver 127.0.0.2\n' | sudo tee /etc/resolver/install.greenhouse
	sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
	@echo ""
	@echo "Done. *.install.greenhouse resolves to 127.0.0.1 on your Mac."
	@echo "To verify what external-dns wrote to CoreDNS, bypass the resolver with:"
	@echo "  dig @127.0.0.1 -p 5354 <hostname>.install.greenhouse +short"

show-e2e-logs:
	@for f in $(E2E_RESULT_DIR)/greenhouse-$(SCENARIO)-*.txt; do \
  		if [ -e "$$f" ]; then \
			echo echo -e "\n\n\n--------------------------- Greenhouse Controller Logs ---------------------------\n\n\n"; \
			cat "$$f"; \
		fi; \
	done
	@for f in $(E2E_RESULT_DIR)/flux-$(SCENARIO)-*.txt; do \
  		if [ -e "$$f" ]; then \
			echo -e "\n\n\n--------------------------- Flux $$f ---------------------------\n\n\n"; \
			cat "$$f"; \
		fi; \
	done

