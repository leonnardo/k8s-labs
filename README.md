# k8s-labs

Local Kubernetes lab on [kind](https://kind.sigs.k8s.io/), built one layer at a
time: Flux, Istio ambient, Flagger and observability.

Only the first layer exists so far: a cluster where Flux reconciles whatever is
in [`cluster/`](cluster), with no Git push in the loop.

## Requirements

Docker, `kind`, `kubectl`, `helm` and the `flux` CLI. Tested on Linux with:

| Tool          | Version                    |
| ------------- | -------------------------- |
| kind          | v0.33.0 (Kubernetes v1.37) |
| kubectl       | v1.37.3                    |
| helm          | v4.3.2                     |
| flux CLI      | v2.10.0                    |
| Flux Operator | 0.64.0, installs Flux 2.10 |

## Usage

```sh
make up     # create the cluster and bootstrap Flux from ./cluster
make sync   # push ./cluster and have Flux reconcile it now
make down   # delete the cluster
```

The loop is: edit files under `cluster/`, run `make sync`, watch Flux apply
them. Nothing has to be committed first.

Every command names the `kind-k8s-labs` context explicitly, so the lab never
touches the cluster your current kubeconfig context points at.

## How it works

```
cluster/ ── make sync ──> registry (in the cluster) ──> Flux ──> cluster state
            flux push artifact        OCIRepository + Kustomization
```

- `make sync` packages `cluster/` as an OCI artifact and pushes it to a registry
  that runs inside the cluster, exposed to the host on `localhost:5050`.
- The `FluxInstance` tells the Flux Operator to generate an `OCIRepository` and
  a `Kustomization`, both named `flux-system`, that pull that artifact through
  the in-cluster Service and apply it with pruning.
- Flux tracks the artifact digest. The digest only changes when `cluster/` or
  `HEAD` changes, so repeating `make sync` is a no-op.

Everything in [`bootstrap/`](bootstrap) is applied by `make up`, not by Flux,
because it has to exist before Flux has anything to sync:

| File                 | What it is                                        |
| -------------------- | ------------------------------------------------- |
| `kind.yaml`          | Cluster definition and the registry port mapping  |
| `registry.yaml`      | The in-cluster registry                           |
| `flux-instance.yaml` | Flux version, components and where it syncs from  |

### Things to know

- The registry stores the artifact in an `emptyDir`. If its pod is replaced,
  the `OCIRepository` fails to fetch until you run `make sync` again.
- The registry speaks plain HTTP, which is why the `FluxInstance` patches the
  generated `OCIRepository` with `insecure: true` and `make sync` pushes with
  `--insecure-registry`.

## Roadmap

1. ~~kind, in-cluster registry, Flux Operator, `make sync`~~
2. Gateway API, Istio ambient and an ingress Gateway
3. kube-prometheus-stack
4. Flagger with a canary driven through the Gateway API
5. Loki, Tempo and OpenTelemetry

After that: Cilium as the CNI, LoadBalancer IPs and several Gateway API
controllers side by side.
