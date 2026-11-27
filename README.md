# k8s-labs

Local Kubernetes lab on [kind](https://kind.sigs.k8s.io/), built one layer at a
time: Flux, Istio ambient, Flagger and observability.

Two layers exist so far: a cluster where Flux reconciles whatever is in
[`cluster/`](cluster) with no Git push in the loop, and on top of it Istio in
ambient mode with a Gateway reachable from the host.

## Requirements

Docker, `kind`, `kubectl`, `helm` and the `flux` CLI. Give Docker at least 4
CPUs: the default CPU requests add up to about 2.3 cores, and on a 2-CPU
machine `istiod` stays Pending.

Tested on Linux with:

| Component     | Version                    |
| ------------- | -------------------------- |
| kind          | v0.33.0 (Kubernetes v1.37) |
| kubectl       | v1.37.3                    |
| helm          | v4.3.2                     |
| flux CLI      | v2.10.0                    |
| Flux Operator | 0.64.0, installs Flux 2.10 |
| Gateway API   | v1.6.1, standard channel   |
| Istio         | 1.32.0, ambient mode       |

## Usage

```sh
make up     # create the cluster and wait until every layer is ready
make sync   # push ./cluster and have Flux reconcile it now
make down   # delete the cluster
```

The loop is: edit files under `cluster/`, run `make sync`, watch Flux apply
them. Nothing has to be committed first.

Every command names the `kind-k8s-labs` context explicitly, so the lab never
touches the cluster your current kubeconfig context points at.

### Exposing an app

The Gateway answers on `http://<name>.localhost:8080`. Attach an `HTTPRoute`
from any namespace:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app
  namespace: my-app
spec:
  parentRefs:
    - name: ingress
      namespace: istio-ingress
  hostnames:
    - my-app.localhost
  rules:
    - backendRefs:
        - name: my-app
          port: 80
```

To put a namespace in the mesh, label it `istio.io/dataplane-mode: ambient`.
Its pods then talk mTLS through ztunnel, with no sidecars.

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

### What Flux reconciles

[`cluster/kustomization.yaml`](cluster/kustomization.yaml) lists one Flux
`Kustomization` per component. Each applies the directory of the same name and
waits for the one before it:

| Kustomization | Applies                                               | Depends on    |
| ------------- | ----------------------------------------------------- | ------------- |
| `gateway-api` | Gateway API CRDs, fetched from upstream at a tag      |               |
| `istio`       | `istio-base`, `istiod`, `istio-cni`, `ztunnel` charts | `gateway-api` |
| `ingress`     | The `ingress` Gateway in `istio-ingress`              | `istio`       |

Istio deploys an Envoy for the Gateway and exposes it as a NodePort, which
`bootstrap/kind.yaml` maps to `localhost:8080`.

### What `make up` applies itself

Everything in [`bootstrap/`](bootstrap) is applied by `make up`, not by Flux,
because it has to exist before Flux has anything to sync:

| File                 | What it is                                        |
| -------------------- | ------------------------------------------------- |
| `kind.yaml`          | Cluster definition and the host port mappings     |
| `registry.yaml`      | The in-cluster registry                           |
| `flux-instance.yaml` | Flux version, components and where it syncs from  |

### Things to know

- `make sync` returns once the root Kustomization is applied. The component
  Kustomizations pick up the new artifact right after and reconcile on their
  own; follow them with
  `flux --context kind-k8s-labs get kustomizations --watch`.
- Port mappings in `bootstrap/kind.yaml` only take effect when the cluster is
  created. After changing them, run `make down` and `make up`.
- The registry stores the artifact in an `emptyDir`. If its pod is replaced,
  the `OCIRepository` fails to fetch until you run `make sync` again.
- The registry speaks plain HTTP, which is why the `FluxInstance` patches the
  generated `OCIRepository` with `insecure: true` and `make sync` pushes with
  `--insecure-registry`.

## Roadmap

1. ~~kind, in-cluster registry, Flux Operator, `make sync`~~
2. ~~Gateway API, Istio ambient and an ingress Gateway~~
3. kube-prometheus-stack
4. Flagger with a canary driven through the Gateway API
5. Loki, Tempo and OpenTelemetry

After that: Cilium as the CNI, LoadBalancer IPs and several Gateway API
controllers side by side.
