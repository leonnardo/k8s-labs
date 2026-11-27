CLUSTER               := k8s-labs
FLUX_OPERATOR_VERSION := 0.64.0

# Host side of the in-cluster registry (bootstrap/kind.yaml). The repository
# name has to match sync.url in bootstrap/flux-instance.yaml.
ARTIFACT := oci://localhost:5050/k8s-labs:latest

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
up: cluster registry push flux ## Create the cluster and bootstrap Flux from ./cluster

.PHONY: sync
sync: push ## Push ./cluster and have Flux reconcile it now
	$(FLUX) reconcile kustomization flux-system --with-source

.PHONY: down
down: ## Delete the cluster
	kind delete cluster --name $(CLUSTER)

.PHONY: cluster
cluster:
	@kind get clusters 2>/dev/null | grep -qx $(CLUSTER) \
		|| kind create cluster --name $(CLUSTER) --config bootstrap/kind.yaml --wait 120s

.PHONY: registry
registry:
	$(KUBECTL) apply -f bootstrap/registry.yaml
	$(KUBECTL) -n registry rollout status deployment/registry --timeout=120s

# Flux tracks the artifact digest, so uncommitted changes are picked up too;
# --revision only records which commit the working tree was based on.
# --reproducible keeps the digest stable while ./cluster and HEAD are unchanged.
.PHONY: push
push:
	flux push artifact $(ARTIFACT) \
		--path=./cluster \
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
