# A second lab can run next to the first one under another name, with its own
# host ports and data, for example:
#   make up CLUSTER=k8s-labs-2 HTTP_PORT=8081 REGISTRY_PORT=5051
# Pass the same variables to every other target.
CLUSTER       := k8s-labs
# Host port of the ingress Gateway.
HTTP_PORT     := 8080
# Host port of the in-cluster registry. 5050 because macOS AirPlay Receiver
# holds 5000.
REGISTRY_PORT := 5050

FLUX_OPERATOR_VERSION := 0.64.0
# Keep in step with the tag in apps/kube-system/cilium/app/release.yaml.
CILIUM_VERSION        := 1.20.5

# The repository name has to match sync.url in bootstrap/flux-instance.yaml.
ARTIFACT := oci://localhost:$(REGISTRY_PORT)/k8s-labs:latest

# Host directory mounted into the node (bootstrap/kind.yaml). PersistentVolumes
# live here, so their data survives `make down`.
DATA_DIR := $(HOME)/.local/share/$(CLUSTER)

# Every command names the kind context, so the lab never touches whatever
# cluster the current kubeconfig context points at.
CONTEXT := kind-$(CLUSTER)
KUBECTL := kubectl --context $(CONTEXT)
HELM    := helm --kube-context $(CONTEXT)
FLUX    := flux --context $(CONTEXT)

.DEFAULT_GOAL := help

.PHONY: help
help: ## List the targets
	@awk -F ':.*## ' '/^[a-z-]+:.*## / {printf "  %-10s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: up
up: cluster cilium registry push flux ## Create the cluster and bootstrap Flux from ./clusters

.PHONY: sync
sync: push ## Push ./apps and ./clusters and have Flux reconcile them now
	$(FLUX) reconcile kustomization flux-system --with-source

.PHONY: down
down: ## Delete the cluster
	kind delete cluster --name $(CLUSTER)

.PHONY: cluster
cluster:
	@mkdir -p $(DATA_DIR)/prometheus $(DATA_DIR)/loki $(DATA_DIR)/tempo
	@kind get clusters 2>/dev/null | grep -qx $(CLUSTER) \
		|| sed -e 's|DATA_DIR|$(DATA_DIR)|' -e 's|HTTP_PORT|$(HTTP_PORT)|' \
			-e 's|REGISTRY_PORT|$(REGISTRY_PORT)|' bootstrap/kind.yaml \
		| kind create cluster --name $(CLUSTER) --config -

# The cluster is created with no CNI, so nothing runs until Cilium is in, Flux
# included. Flux takes the release over afterwards (apps/kube-system/cilium)
# and reads the same values file, so this only runs when there is no release.
.PHONY: cilium
cilium:
	@$(HELM) -n kube-system status cilium >/dev/null 2>&1 \
		|| $(HELM) install cilium oci://quay.io/cilium/charts/cilium \
			--version $(CILIUM_VERSION) --namespace kube-system \
			--values apps/kube-system/cilium/app/values.yaml --wait
	$(KUBECTL) wait node --all --for=condition=Ready --timeout=2m

.PHONY: registry
registry:
	$(KUBECTL) apply -f bootstrap/registry.yaml
	$(KUBECTL) -n registry rollout status deployment/registry --timeout=120s

# Flux tracks the artifact digest, so uncommitted changes are picked up too;
# --revision only records which commit the working tree was based on.
# --reproducible keeps the digest stable while the manifests and HEAD are
# unchanged. Only ./apps and ./clusters go into the artifact.
.PHONY: push
push:
	flux push artifact $(ARTIFACT) \
		--path=. \
		--ignore-paths="/*,!/apps/,!/clusters/" \
		--source="$$(git config --get remote.origin.url)" \
		--revision="$$(git branch --show-current)@sha1:$$(git rev-parse HEAD)" \
		--reproducible \
		--insecure-registry

.PHONY: flux
flux:
	$(HELM) upgrade --install flux-operator \
		oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
		--version $(FLUX_OPERATOR_VERSION) \
		--namespace flux-system --create-namespace --wait
	$(KUBECTL) apply -f bootstrap/flux-instance.yaml
	$(KUBECTL) -n flux-system wait fluxinstance/flux --for=condition=Ready --timeout=5m
	$(KUBECTL) -n flux-system wait kustomization/flux-system --for=condition=Ready --timeout=2m
	$(KUBECTL) -n flux-system wait kustomization --all --for=condition=Ready --timeout=15m
