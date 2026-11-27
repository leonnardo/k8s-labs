# k8s-labs

Local Kubernetes lab on [kind](https://kind.sigs.k8s.io/), built one layer at a
time: Flux, Istio ambient, Flagger and observability.

Three layers exist so far: a cluster where Flux reconciles whatever is in
[`apps/`](apps) with no Git push in the loop, on top of it Istio in
ambient mode with a Gateway reachable from the host, and Prometheus,
Alertmanager and Grafana watching all of it.

## Requirements

Docker, `kind`, `kubectl`, `helm` and the `flux` CLI. Give Docker at least 4
CPUs: the default CPU requests add up to about 2.4 cores, and on a 2-CPU
machine `istiod` stays Pending.

Tested on macOS with OrbStack (the first two layers also on Linux) with:

| Component     | Version                    |
| ------------- | -------------------------- |
| kind          | v0.33.0 (Kubernetes v1.37) |
| kubectl       | v1.37.3                    |
| helm          | v4.3.2                     |
| flux CLI      | v2.10.0                    |
| Flux Operator | 0.64.0, installs Flux 2.10 |
| Gateway API   | v1.6.1, standard channel   |
| Istio         | 1.32.0, ambient mode       |
| cert-manager  | v1.21.3                    |
| metrics-server | chart 3.14.0              |
| kube-prometheus-stack | chart 94.1.0       |

## Usage

```sh
make up     # create the cluster and wait until every layer is ready
make sync   # push ./apps and ./clusters and have Flux reconcile them now
make down   # delete the cluster
```

The loop is: edit files under `apps/`, run `make sync`, watch Flux apply
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

### Observability

| URL                                  | What                         |
| ------------------------------------ | ---------------------------- |
| <http://grafana.localhost:8080>      | Grafana, no login, as admin  |
| <http://prometheus.localhost:8080>   | Prometheus                   |
| <http://alertmanager.localhost:8080> | Alertmanager, no receivers   |

Prometheus picks up every `ServiceMonitor`, `PodMonitor`, `PrometheusRule`,
`Probe` and `ScrapeConfig` in the cluster, from any namespace and with no
label required.

Its data is stored on the host, in `~/.local/share/k8s-labs/prometheus`, and
survives `make down`. Delete that directory to start empty.

To put a namespace in the mesh, label it `istio.io/dataplane-mode: ambient`.
Its pods then talk mTLS through ztunnel, with no sidecars.

## How it works

```
apps/ + clusters/ ── make sync ──> registry (in the cluster) ──> Flux ──> cluster state
            flux push artifact        OCIRepository + Kustomization
```

- `make sync` packages `apps/` and `clusters/` as an OCI artifact and pushes it to a registry
  that runs inside the cluster, exposed to the host on `localhost:5050`.
- The `FluxInstance` tells the Flux Operator to generate an `OCIRepository` and
  a `Kustomization`, both named `flux-system`, that pull that artifact through
  the in-cluster Service and apply it with pruning.
- Flux tracks the artifact digest. The digest only changes when those directories or
  `HEAD` changes, so repeating `make sync` is a no-op.

### What Flux reconciles

```
clusters/k8s-labs/kustomization.yaml    # the namespaces this cluster runs
apps/<namespace>/
  kustomization.yaml                    # the namespace and its apps
  namespace.yaml
  <app>/
    ks.yaml                             # Flux Kustomization(s) for the app
    app/                                # what the Kustomization applies
```

Flux applies [`clusters/k8s-labs`](clusters/k8s-labs/kustomization.yaml), which
creates the namespaces and every `ks.yaml`. Each `ks.yaml` is a Flux
`Kustomization` that applies the `app/` directory next to it and waits for the
ones it depends on. An app is filed under the namespace it installs into;
cluster-wide ones such as the Gateway API CRDs are under `kube-system`.

| Kustomization | In | Applies | Depends on |
| --- | --- | --- | --- |
| `gateway-api` | `kube-system/gateway-api` | Gateway API CRDs, fetched from upstream at a tag | |
| `istio` | `istio-system/istio` | `istio-base`, `istiod`, `istio-cni`, `ztunnel` charts | `gateway-api` |
| `ingress` | `istio-ingress/ingress` | The `ingress` Gateway | `istio` |
| `cert-manager` | `cert-manager/cert-manager` | The `cert-manager` chart | |
| `metrics-server` | `kube-system/metrics-server` | The `metrics-server` chart, for `kubectl top` | |
| `kube-prometheus-stack` | `observability/kube-prometheus-stack` | The chart, the Prometheus volume and the three `HTTPRoute`s | `cert-manager`, `ingress` |
| `istio-monitoring` | `istio-system/istio`, directory `monitors/` | Monitors for istiod, ztunnel and the Gateways | `istio`, `kube-prometheus-stack` |

Custom resources go in a separate Kustomization from the chart that installs
their CRDs, which is why the Istio monitors are a second Kustomization in the same
`ks.yaml`, with their own directory. Flux validates
everything in a Kustomization before applying any of it, and a `PodMonitor`
next to the release that brings its CRD would never pass.

Istio deploys an Envoy for the Gateway and exposes it as a NodePort, which
`bootstrap/kind.yaml` maps to `localhost:8080`.

### What `make up` applies itself

Everything in [`bootstrap/`](bootstrap) is applied by `make up`, not by Flux,
because it has to exist before Flux has anything to sync:

| File                 | What it is                                        |
| -------------------- | ------------------------------------------------- |
| `kind.yaml`          | Cluster definition, host port mappings, the data mount and the control-plane metrics endpoints |
| `registry.yaml`      | The in-cluster registry                           |
| `flux-instance.yaml` | Flux version, components and where it syncs from  |

### Things to know

- `make sync` returns once the root Kustomization is applied. The component
  Kustomizations pick up the new artifact right after and reconcile on their
  own; follow them with
  `flux --context kind-k8s-labs get kustomizations --watch`.
- `bootstrap/kind.yaml` only takes effect when the cluster is created. After
  changing it, run `make down` and `make up`.
- kubeadm binds the metrics of etcd, the scheduler, the controller manager and
  kube-proxy to localhost. `bootstrap/kind.yaml` moves them to `0.0.0.0` so
  that Prometheus can scrape them.
- HTTP metrics such as `istio_requests_total` exist only for traffic that
  enters through the Gateway. Between ambient pods there is no waypoint yet,
  so ztunnel reports L4 metrics only (`istio_tcp_*`).
- A route can answer 503 for a few seconds after its backend pod turns Ready.
- The registry stores the artifact in an `emptyDir`. If its pod is replaced,
  the `OCIRepository` fails to fetch until you run `make sync` again.
- The registry speaks plain HTTP, which is why the `FluxInstance` patches the
  generated `OCIRepository` with `insecure: true` and `make sync` pushes with
  `--insecure-registry`.

## Roadmap

1. ~~kind, in-cluster registry, Flux Operator, `make sync`~~
2. ~~Gateway API, Istio ambient and an ingress Gateway~~
3. ~~kube-prometheus-stack, with cert-manager and metrics-server~~
4. Flagger with a canary driven through the Gateway API
5. Loki, Tempo and OpenTelemetry

After that: Cilium as the CNI, LoadBalancer IPs and several Gateway API
controllers side by side.
