# k8s-labs

Local Kubernetes lab on [kind](https://kind.sigs.k8s.io/), built one layer at a
time: Flux, Istio ambient, Flagger and observability.

Five layers exist so far: a cluster where Flux reconciles whatever is in
[`apps/`](apps) with no Git push in the loop, on top of it Istio in
ambient mode with a Gateway reachable from the host, Prometheus, Alertmanager
and Grafana watching all of it, Flagger releasing a demo app as a canary, and
logs and traces collected with OpenTelemetry into Loki and Tempo.

## Requirements

Docker, `kind`, `kubectl`, `helm` and the `flux` CLI. Give Docker at least 4
CPUs: the default CPU requests add up to about 2.5 cores, and on a 2-CPU
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
| Flagger       | 1.45.0, loadtester chart 0.39.0 |
| podinfo       | 6.17.0                     |
| Loki          | chart 21.6.2 (Loki 3.7)    |
| Tempo         | chart 3.2.1 (Tempo 3.1)    |
| OpenTelemetry Operator | chart 0.129.2, collector 0.162.0 |

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

Logs and traces are in Grafana's Explore view, under the Loki and Tempo
datasources:

- Logs of every container, labeled `k8s_namespace_name`, `k8s_pod_name` and
  `k8s_container_name`. For example `{k8s_namespace_name="podinfo"}`.
- A trace for every request that enters through the Gateway or passes
  through a waypoint. Requests to podinfo carry a second span from the app
  itself.
- From a span, "Logs for this span" opens the logs of the pod that produced it.

Metrics, logs and traces are stored on the host, in
`~/.local/share/k8s-labs/{prometheus,loki,tempo}`, and survive `make down`.
Delete a directory to start empty. Logs are kept for 7 days and traces for 3.

### Releasing a canary

<http://podinfo.localhost:8080> is a demo app managed by Flagger. Change
anything in the pod template of
[`apps/podinfo/podinfo/app/deployment.yaml`](apps/podinfo/podinfo/app/deployment.yaml),
for example `PODINFO_UI_MESSAGE` or the image tag, and run `make sync`. Then
watch:

```sh
kubectl --context kind-k8s-labs -n podinfo get canary podinfo --watch
kubectl --context kind-k8s-labs -n podinfo describe canary podinfo
```

Flagger starts the new version next to the old one and moves traffic to it
through the weights of an `HTTPRoute`: 20%, 40%, 60%, one step every 30
seconds. At each step it asks Prometheus for the error rate and the latency of
the new version, as seen by the Gateway. If they stay within bounds the new
version is promoted, in about four minutes; after five failed checks it is
rolled back.

The same weights apply to requests from inside the mesh to
`podinfo.podinfo:9898`, because the route is also attached to that Service and
the namespace has a waypoint.

To see a rollback, request errors while a release is in progress. They count
against the new version only:

```sh
while true; do curl -s -o /dev/null http://podinfo.localhost:8080/status/500; done
```

To put a namespace in the mesh, label it `istio.io/dataplane-mode: ambient`.
Its pods then talk mTLS through ztunnel, with no sidecars.

ztunnel only handles TCP. For HTTP metrics, traces and routing between pods, a
namespace needs a waypoint: a `Gateway` of class `istio-waypoint` and the
label `istio.io/use-waypoint` on the namespace, as in
[`apps/podinfo`](apps/podinfo). Only `podinfo` has one.

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
| `istio-monitoring` | `istio-system/istio`, directory `monitors/` | Monitors for istiod, ztunnel, the Gateways and the waypoints | `istio`, `kube-prometheus-stack` |
| `flagger` | `flagger-system/flagger` | The `flagger` chart | `gateway-api`, `kube-prometheus-stack` |
| `flagger-metrics` | `flagger-system/flagger`, directory `metrics/` | The `MetricTemplate`s a canary analysis can use | `flagger` |
| `loadtester` | `flagger-system/loadtester` | The `loadtester` chart, which generates traffic during an analysis | |
| `podinfo-waypoint` | `podinfo/waypoint` | The waypoint of the `podinfo` namespace | `istio` |
| `podinfo` | `podinfo/podinfo` | The demo Deployment and its `Canary` | `ingress`, `podinfo-waypoint`, `flagger-metrics`, `loadtester` |
| `loki` | `observability/loki` | The `loki` chart as a single instance, its volume and its Grafana datasource | `kube-prometheus-stack` |
| `tempo` | `observability/tempo` | The `tempo` chart, its volume and its Grafana datasource | `kube-prometheus-stack` |
| `opentelemetry-operator` | `observability/opentelemetry-operator` | The `opentelemetry-operator` chart | `cert-manager` |
| `otel-agent` | `observability/opentelemetry-operator`, directory `collector/` | A collector on every node: container logs to Loki, OTLP traces to Tempo | `opentelemetry-operator`, `loki`, `tempo` |

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
- HTTP metrics such as `istio_requests_total` exist for traffic that enters
  through the Gateway (`reporter="source"`) and for traffic to a Service of a
  namespace with a waypoint (`reporter="waypoint"`). Elsewhere ztunnel
  reports L4 metrics only (`istio_tcp_*`).
- Traffic from the Gateway goes straight to the pods and skips the waypoint.
  Istio sends it through the waypoint only for a Service labeled
  `istio.io/ingress-use-waypoint`, which the lab does not set.
- Flagger runs with the `gatewayapi:v1` provider, so a canary only depends on
  `HTTPRoute`. What is specific to Istio are the queries in
  `apps/flagger-system/flagger/metrics/istio.yaml`; another Gateway controller
  needs its own.
- A canary is judged only on traffic that enters through the Gateway, which is
  why the load generator calls the Gateway and not the Service.
- The `podinfo` Kustomization is Ready when its canary is `Initialized` or
  `Succeeded`. After a rollback it reports the failure on the next `make sync`
  until a release succeeds.
- Traces come from Envoy, so from the Gateway and the waypoints. ztunnel
  does not trace, and pod-to-pod traffic in a namespace with no waypoint has
  no spans of its own.
  An app that speaks OTLP can send to
  `otel-agent-collector.observability:4317`, as podinfo does.
- In istiod's `meshConfig`, `defaultProviders` replaces Istio's built-in
  defaults. Listing only a tracing provider silently turns off
  `istio_requests_total`, and every canary then fails for lack of metrics.
- Volumes are static `hostPath` volumes of class `host`. Each one names the
  claim it is for, since a claim without a selector would otherwise take any
  of them.
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
4. ~~Flagger with a canary driven through the Gateway API~~
5. ~~Loki, Tempo and OpenTelemetry~~
6. ~~A waypoint for podinfo, so that the canary also applies inside the mesh~~

After that: Cilium as the CNI, LoadBalancer IPs and several Gateway API
controllers side by side.
