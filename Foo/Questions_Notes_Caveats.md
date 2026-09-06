# Questions, Notes, and Caveats

## Questions
- Will the primary IP of the device change?
  - if yes, need to create a workaround?

- Will the applications be accessed via hostname (or IP, or both?)

- How do you handle Certificates in Docker/Podman?  
NOTE: there is a certificate dependency (and integration) that will need to be addressed

## Notes, and Caveats
* Currently there is an issue with RHEL 10 + firewalld when using Canal/Flannel.  At this time, firewalld will need to be disabled.

* Using Rancher Manager on a single-node RKE2 instance running on bare metal does not afford you the advantage of connecting Rancher to a provider for the **Full** Lifecycle Management of a Kubernetes cluster.  You can, however, deploy your own additional K3s/RKE2 clusters on the device and "Import Existing" - which then allows you to manage the cluster with Rancher - giving you all the other advantages.

* Kubernetes will use an Ingress rather than the port mapping you might be accustomed to using docker/podman (see below).

## Exposing an application outside the cluster (for Podman/Docker users)

With Podman you publish a container straight onto the host and pick the port:

```bash
podman run -d -p 8080:80 docker.io/library/nginx:alpine
# reachable immediately at http://<this-host>:8080
```

Kubernetes has **no equivalent to `-p`**. A Pod gets an internal, ephemeral IP (here in `10.42.0.0/16`) that is not routable from outside the node and changes on every restart. Reaching it from the outside is a layered, declarative job — you apply YAML objects to the cluster API, you don't pass flags to a run command:

| Layer | What it is | Podman analogy |
|---|---|---|
| **Deployment / Pod** | Runs the container(s). `containerPort` is documentation only — it publishes nothing. | `podman run` (minus `-p`) |
| **Service** | Stable virtual IP + in-cluster DNS name (`app.ns.svc.cluster.local`) that load-balances to the Pods. Type `ClusterIP` (default) is **still cluster-internal only**. | the container's own IP, but stable and named |
| **Ingress** | L7 HTTP/HTTPS router. One shared entrypoint on the node's `:80`/`:443` (Traefik, bundled with RKE2, bound to the node via the `externalIPs` setup in `Procedure.md` §5) that routes to Services **by DNS hostname and/or URL path**. | the `-p` publish step — but shared, and keyed on hostname instead of port |

### Minimal example

nginx, reachable at `https://hello.community.kubernerdes.com/`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: hello, namespace: demo }
spec:
  replicas: 1
  selector: { matchLabels: { app: hello } }
  template:
    metadata: { labels: { app: hello } }
    spec:
      containers:
      - name: nginx
        image: docker.io/library/nginx:alpine
        ports: [{ containerPort: 80 }]
---
apiVersion: v1
kind: Service
metadata: { name: hello, namespace: demo }
spec:
  selector: { app: hello }          # <-- matches the Pod labels above
  ports: [{ port: 80, targetPort: 80 }]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: { name: hello, namespace: demo }
spec:
  ingressClassName: traefik         # optional here (traefik is the default class), explicit is clearer
  rules:
  - host: hello.community.kubernerdes.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend: { service: { name: hello, port: { number: 80 } } }
```

```bash
kubectl create namespace demo
kubectl apply -f hello.yaml
```

### What changes in your mental model

* **You don't choose a host port.** All HTTP/HTTPS enters through Traefik on `:80`/`:443`. Differentiation is by **hostname**, not port.
* **The DNS name is load-bearing.** Traefik routes on the `Host:` header, so a real DNS record (or an `/etc/hosts` line) for `hello.community.kubernerdes.com` must point at the node's IP. Browsing the bare node IP returns a Traefik **`404 page not found`** — that is expected, not a failure.
* **The Service is mandatory.** An Ingress always points at a Service, never directly at a Pod. Deployment + Service + Ingress is the minimum; there is no shortcut object.
* **TLS moves out of the container.** The Ingress terminates TLS. Provide a cert `Secret` and reference it under `spec.tls`, or use cert-manager. cert-manager is already installed (for Rancher) but only has Rancher's private self-signed `Issuer` — for your own apps you create your own `ClusterIssuer` (self-signed, an internal CA, or ACME/Let's Encrypt) and add the `cert-manager.io/cluster-issuer: <name>` annotation to the Ingress.
* **It's all declarative and idempotent.** The YAML lives in the cluster; re-`kubectl apply` to change it. Rancher's UI ("Service Discovery → Ingresses", "Workload") is just a front-end over these same objects.

### When Ingress is the wrong tool

Ingress is HTTP/HTTPS only. For a raw **TCP or UDP** service (database, MQTT broker, syslog, game server, …) use one of:

* **NodePort Service** — binds a port in the `30000–32767` range on every node. The closest thing to `-p`, but the port is high and auto-assigned unless you pin `nodePort:` explicitly. One port per service.
* **Traefik `IngressRouteTCP` / `IngressRouteUDP`** (CRDs are installed) — but the bundled Traefik only exposes the `web` and `websecure` (HTTP) entrypoints; a TCP/UDP route needs a dedicated entrypoint added via a `HelmChartConfig` for `rke2-traefik` (same mechanism as `Procedure.md` §5).
* **`hostPort` on the Pod spec** — the literal `-p` equivalent: binds the chosen port on whichever node the Pod runs on. Works, but generally discouraged — it collides with other Pods wanting the same port and breaks when the Pod reschedules.

### Quick local testing (no Service/Ingress)

`kubectl port-forward` is the throwaway equivalent of an SSH tunnel — it lasts only while the command runs and only serves the machine you run it on:

```bash
kubectl -n demo port-forward svc/hello 8080:80   # then: curl http://localhost:8080
```

Never use it for real exposure.

