# Kubernetes Performance Benchmark on Dell Pro Rugged Tablet 12 (RA02260)

> [!NOTE]
> If the primary interface for the Tablet changes, you will need to update the config. (procedure will be towards bottom of this doc)

This document outlines the end-to-end process for benchmarking bare-metal Red Hat Enterprise Linux (RHEL) 10.2 against two lightweight Kubernetes distributions (K3s and RKE2). You can update the tables at the bottom as you complete each iteration.

## Testing Methodology
We will use **sysbench** to test CPU and Memory overhead, and **fio** to test storage I/O.
1. **Baseline**: Run tests directly on the RHEL 10.2 OS.
2. **K3s**: Install K3s, run the tests inside a Kubernetes Pod, and record results.
3. **RKE2**: Wipe, fresh RHEL 10.2 install, install RKE2, run the tests inside a Pod, and record results.

---

## Phase 1: Baseline (RHEL 10.2 Bare Metal)

### 1. Initial OS Setup
1. Install a fresh instance of RHEL 10.2 on the Dell Pro Rugged 12 Tablet.
- Connect remote USB Keyboard and Mouse
- press power button then F2 repeatedly
- PXE should be used for this kind of testing - I do not have time to build a PXE environment at this point.

2. Update the system and install benchmarking tools:
```bash
sudo dnf update -y
sudo shutdown now -r
``` 

2a. Add/enable REPOs
```bash
  # 1. Enable CodeReady Builder (EPEL expects it)
  sudo subscription-manager repos --enable codeready-builder-for-rhel-10-x86_64-rpms

  # 2. Install EPEL for RHEL 10
  sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm

  # 3. Install both tools
  sudo dnf install -y fio sysbench
```

Create Results directories
```bash
mkdir -p ~/Results/RHEL-10.2
mkdir -p ~/Results/RHEL-10.2-K3s
mkdir -p ~/Results/RHEL-10.2-RKE2
```

### 2. Run Baseline Benchmarks

#### CPU Benchmark (Calculates primes up to 20000 across 4 threads)
```bash
TODAY=$(date +%F)
echo "--- CPU TEST ---" | tee ~/Results/RHEL-10.2/sysbench-cpu-mem-$TODAY.out
sysbench cpu --cpu-max-prime=20000 --threads=4 run | tee -a ~/Results/RHEL-10.2/sysbench-cpu-mem-$TODAY.out
```
*(Record the "events per second" and "total time" in the Results Table)*

#### Memory Benchmark (Tests read/write speed)
```bash
echo "--- MEMORY TEST ---" | tee -a ~/Results/RHEL-10.2/sysbench-cpu-mem-$TODAY.out
sysbench memory --memory-block-size=1K --memory-total-size=10G --threads=4 run | tee -a ~/Results/RHEL-10.2/sysbench-cpu-mem-$TODAY.out
```
*(Record the "MiB transferred" and "Total operations" in the Results Table)*

---

## Phase 2: K3s Evaluation

### 1. K3s Installation
Since K3s is a single-binary Kubernetes distribution, installation is very quick.  I did not pin to a specific version - if I was doing this task repeatedly and over time, I would probably either pin, or record the results with the version number as a reference.

#### Install K3s
```bash
curl -sfL https://get.k3s.io | sh -
mkdir ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $(whoami) ~/.kube/config; chmod 0664 ~/.kube/config; 
echo "export KUBECONFIG=~/.kube/config" | tee -a ~/.bashrc
. ~/.bashrc
```

#### Verify node is ready
```bash
k3s kubectl get nodes
```

### 2. Run K3s Benchmarks
We will deploy a Kubernetes Job that spins up an Ubuntu container, installs sysbench, and runs the same tests.

#### Create the Job manifest `k3s-bench.yaml`
```
cat << EOF | tee k3s-bench.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: benchmark-job-cpu-mem
spec:
  template:
    spec:
      # The node's /etc/resolv.conf carries the "evil.corp" search domain, and
      # that zone answers *every* name with a wildcard A record (192.168.1.10,
      # an unrouted host). With the default pod ndots:5, glibc (apt) tries
      # "security.ubuntu.com.evil.corp" before the real name and gets poisoned,
      # hence "No route to host". ndots:1 makes the absolute name win first.
      dnsConfig:
        options:
          - name: ndots
            value: "1"
      containers:
      - name: sysbench
        image: ubuntu:latest
        command: ["/bin/sh", "-c"]
        args:
          - apt-get update && apt-get install -y sysbench;
            echo "--- CPU TEST ---";
            sysbench cpu --cpu-max-prime=20000 --threads=4 run;
            echo "--- MEMORY TEST ---";
            sysbench memory --memory-block-size=1K --memory-total-size=10G --threads=4 run;
      restartPolicy: Never
  backoffLimit: 0
EOF
```

#### Apply the benchmark Job
```bash
kubectl apply -f k3s-bench.yaml
```

#### Wait for the job to complete, then view the results
```bash
k3s kubectl logs job/benchmark-job-cpu-mem | tee ~/Results/RHEL-10.2-K3s/sysbench-cpu-mem.out
```
*(Record the results in the Results Table)*

#### Uninstall K3s
```bash
 sudo /usr/local/bin/k3s-uninstall.sh
```

---
## Phase 3: RKE2 Evaluation

### 1. RKE2 Installation
**Important:** Wipe the OS and perform a fresh install of RHEL 10.2 to ensure there is no artifacting from K3s.

**Prerequisite:** `post_install.sh` runs `systemctl disable --now firewalld` before this. If you skip that step (or restore a snapshot from before it existed), do it before installing RKE2 -- otherwise pod-to-pod traffic on the same node is silently REJECTed by firewalld's FORWARD chain once you run more than a single-pod workload. Setting `FirewallBackend=iptables` is **not** sufficient; the service has to be stopped. Full write-up: `Foo/Pod-to-Pod-Networking-Bug.md`.

#### Install RKE2 (Rancher Kubernetes Engine 2)
```bash
curl -sfL https://get.rke2.io | sudo sh -
```
#### Enable and start the RKE2 server service
```bash
sudo systemctl enable rke2-server.service
sudo systemctl start rke2-server.service
```
#### Symlink kubectl for ease of use
```bash
sudo ln -s /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl
sudo cat /etc/rancher/rke2/rke2.yaml | tee ~/.kube/config
export KUBECONFIG=~/.kube/config
```
#### Verify node is ready
```bash
kubectl get nodes
```
### 2. Run RKE2 Benchmarks
Deploy the exact same job used in Phase 2.

#### Apply the benchmark Job
```bash
kubectl apply -f k3s-bench.yaml
```

#### Wait for the job to complete, then view the results
```bash
kubectl logs job/benchmark-job-cpu-mem  | tee ~/Results/RHEL-10.2-RKE2/sysbench-cpu-mem.out
```
*(Record the results in the Results Table)*

---

## Phase 4: Rancher Manager Installation (Common to K3s and RKE2)

This phase is identical regardless of which distribution is currently running — Rancher Manager is deployed via Helm on top of whichever cluster (K3s or RKE2) is up at the time. Run this after standing up either cluster if you want to evaluate Rancher's management overhead alongside the raw sysbench/fio numbers.

### 1. Install Helm
```bash
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```
If piping a script to a root shell is blocked in your environment, install from the verified release tarball instead (this is what was used here — Helm **v4.2.4**):
```bash
cd /tmp
VER=$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest | grep -oE '"tag_name": *"[^"]+"' | cut -d'"' -f4)
curl -fsSLO "https://get.helm.sh/helm-${VER}-linux-amd64.tar.gz"
curl -fsSLO "https://get.helm.sh/helm-${VER}-linux-amd64.tar.gz.sha256sum"
sha256sum -c "helm-${VER}-linux-amd64.tar.gz.sha256sum"
tar -xzf "helm-${VER}-linux-amd64.tar.gz"
sudo install -m 0755 linux-amd64/helm /usr/local/bin/helm
helm version
```

### 2. Add the Rancher and Jetstack (cert-manager) Helm repos
```bash
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
helm repo add jetstack https://charts.jetstack.io
helm repo update
```

### 3. Install cert-manager
Rancher requires cert-manager for TLS unless you bring your own certificates. (Used here: cert-manager **v1.21.1**.)
```bash
kubectl create namespace cert-manager
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --set crds.enabled=true
kubectl -n cert-manager rollout status deploy/cert-manager --timeout=180s
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=180s
```

#### Verify cert-manager pods are running
```bash
kubectl get pods --namespace cert-manager
```

### 4. Install Rancher Manager
Set `hostname=` to the DNS name you'll reach the UI on (a DNS A record for it must resolve to the node IP — one was created for this exercise), and choose a real bootstrap password. `replicas=3` is the chart default and is kept here deliberately — it exercises the pod-to-pod HA replica mesh, which is what surfaced the firewalld bug (see `Foo/Pod-to-Pod-Networking-Bug.md`). Used here: Rancher chart **2.15.1**.

```bash
kubectl create namespace cattle-system
helm install rancher rancher-latest/rancher \
  --namespace cattle-system \
  --set hostname=rancher-test.community.kubernerdes.com \
  --set bootstrapPassword=admin123 \
  --set replicas=3
```

#### Wait for the Rancher deployment to roll out
```bash
kubectl -n cattle-system rollout status deploy/rancher --timeout=600s
```
With firewalld disabled (Phase 3 prerequisite) all 3 replicas go `Available` in well under a minute and the logs are free of `Failed to connect to peer wss://...` errors. If that rollout hangs, the pod-to-pod path is broken again — confirm `sudo systemctl is-active firewalld` is `inactive` before anything else.

Shortly after Rancher is up it deploys its own operators (rancher-webhook, Fleet, gitjob). These can log errors / restart for the first 2-3 minutes while CRDs settle — `fleet` in particular may take a couple of retries on its `fleet-migrate-gitrepo-helm-url-regex` pre-upgrade hook before landing `deployed`. A couple of `helm-operation-*` pods may be left behind stuck at `1/2` (their `helm` container failed on an early retry, the proxy sidecar keeps the pod from completing); they are cosmetic — once `helm ls -A` shows every release `deployed`, clean them up:
```bash
kubectl -n cattle-system get pods | awk '/^helm-operation-/ && $3=="Error"{print $1}' \
  | xargs -r kubectl -n cattle-system delete pod
```

### 5. Expose Traefik on the node (required for external access)
RKE2 v1.36.4+rke2r1 ships `rke2-traefik` as `type: ClusterIP`, and RKE2's bundled ServiceLB (klipper) does not run on this hardware -- a `LoadBalancer`-type Service just sits at `EXTERNAL-IP: <pending>` with no `svclb-*` pod, so nothing binds the node's real `:80`/`:443`. The ingress/DNS/cert setup above is correct but unreachable from a browser until the node IP is put on the traefik Service.

On a single node the clean fix is `externalIPs` (kube-proxy then DNATs `<node-ip>:{80,443}` -> traefik). Do it **durably** via a `HelmChartConfig` so the RKE2 helm-controller re-applies it on every reconcile, reboot, and RKE2 upgrade -- an imperative `kubectl patch svc` does not survive a reconcile:

```bash
sudo tee /var/lib/rancher/rke2/server/manifests/rke2-traefik-config.yaml >/dev/null <<'EOF'
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-traefik
  namespace: kube-system
spec:
  valuesContent: |-
    service:
      spec:
        type: ClusterIP
        externalIPs:
          - 10.10.12.185          # <-- the node's primary IP
EOF
```

The helm-controller picks the file up within seconds (re-runs `helm-install-rke2-traefik`). Verify:
```bash
kubectl -n kube-system get helmchartconfig rke2-traefik
kubectl -n kube-system get svc rke2-traefik    # EXTERNAL-IP should now show 10.10.12.185, PORT(S) 80/TCP,443/TCP
```
If the node IP ever changes, edit the address in this `rke2-traefik-config.yaml` and it re-applies -- do **not** edit the bundled `rke2-traefik.yaml` in the same directory, RKE2 overwrites that on every restart/upgrade. (An IP change also means an etcd-membership reset -- see Troubleshooting.)

### 6. Access Rancher
Browse to **`https://rancher-test.community.kubernerdes.com/`** (no port) and log in with the bootstrap password from step 4. The certificate is Rancher's self-signed `dynamiclistener` CA -- click through the browser warning ("Advanced -> Proceed"). You'll be prompted to set a new admin password and confirm the server URL on first login.

Note: traefik routes by `Host:` header, so browsing by **IP** (`https://<node-ip>/`) returns `404 page not found` from traefik's default handler -- that's expected, use the DNS name.

> [!NOTE]
> **Previously logged here as an unresolved HA-mesh hang -- now resolved.** The symptom (all 3 `rancher` pods `1/1 Running` but neither `:80` nor `:443` bound inside the container, logs looping `Failed to connect to peer wss://... connect: connection refused`) was a downstream effect of the pod-to-pod networking bug: Rancher's replicas could not reach each other over the pod network. Root cause was **firewalld** (its FORWARD chain REJECTs pod-to-pod transit; `FirewallBackend=iptables` is *not* enough, the service must be stopped). With `systemctl disable --now firewalld` in place (Phase 3 prerequisite), a fresh 3-replica install rolls out clean in well under a minute. Full write-up: `Foo/Pod-to-Pod-Networking-Bug.md`.

### 7. Uninstall Rancher (between iterations)
If you're re-running this phase against both K3s and RKE2 in turn, tear Rancher down before wiping/reinstalling the underlying cluster:
```bash
helm uninstall rancher --namespace cattle-system
helm uninstall cert-manager --namespace cert-manager
kubectl delete namespace cattle-system cert-manager
```

---

## Results Tracking Matrix

### CPU Performance (Higher Events/sec is better)
| Environment | Events per Second | Total Time (s) | 95th Percentile Latency (ms) |
|:-------------|:-------------------|:----------------|:------------------------------|
| RHEL 10.2 (Baseline) | 5000.06 | 10.0005 | 0.81 |
| K3s Container | 4974.26 | 10.0006 | 0.81 |
| RKE2 Container | 4973.15 | 10.0006 | 0.81 |

### Memory Performance (Higher MiB/sec is better)
| Environment | Total Operations | Transfer Rate (MiB/sec) | 95th Percentile Latency (ms) |
|:-------------|:------------------|:-------------------------|:------------------------------|
| RHEL 10.2 (Baseline) | 10,485,760 | 10654.89 | 0.00 |
| K3s Container | 10,485,760 | 11063.68 | 0.00 |
| RKE2 Container | 10,485,760 | 10646.51 | 0.00 |

### Notes
  - CPU: containerized runs are ~0.5% below bare metal (4974 vs 5000 events/sec) — well within run-to-run noise. Total time and p95 latency are identical across all three. No
    meaningful K3s vs RKE2 difference.
  - Memory: differences are noise, not signal — K3s posted higher than baseline (11064 vs 10655 MiB/sec) and RKE2 landed right on baseline. The --memory-block-size=1K test is
    basically measuring the syscall/loop path, so p95 rounds to 0.00 ms everywhere.
  - This is single-run data. If you want defensible numbers, run each 3–5× and average — the ~1% spread here is smaller than typical thermal variance on a fanless tablet.
  - The K3s/RKE2 .out files include the full apt-get install log ahead of the sysbench output; the DNS fix worked (apt-get pulled from the real Ubuntu mirrors).

---

## Troubleshooting and Maintenance

### Reset config after IP change
Symptom: `systemctl status rke2-server` sits in `activating (start)` indefinitely, and `journalctl -u rke2-server` repeats `Failed to test etcd connection: this server is not a member of the etcd cluster. Found [...old-ip...], expect [...new-ip...]`. Single-node embedded etcd bakes the node's IP into its membership list at bootstrap; a later IP change leaves it unable to match itself.
```bash
  sudo systemctl stop rke2-server
  sudo rke2 server --cluster-reset
  # wait for "Managed etcd cluster membership has been reset, restart without --cluster-reset flag now" -- it exits on its own
  sudo systemctl start rke2-server
  sudo systemctl status rke2-server
```
Certs get auto-backed up to `/var/lib/rancher/rke2/server/tls-<timestamp>/` as part of the reset -- no separate backup step needed.

**Clean up the stale node object.** The reset changes the etcd member's identity, but the *old* `Node` object (registered under the old hostname/IP, e.g. `dhcp-40.evil.corp`) stays behind as `Ready` even though nothing is running there. Every DaemonSet/Deployment pod still scheduled on it (CNI, cert-manager, CoreDNS, your own workloads) will sit in `ContainerCreating`/`CrashLoopBackOff` until you remove it:
```bash
kubectl get nodes                    # confirm the stale entry (old hostname/IP) alongside the current one
kubectl delete node <stale-node-name>
kubectl get pods -A -o wide | grep -v -E 'Running|Completed'   # confirm everything reschedules onto the real node
```

### firewalld blocks pod-to-pod traffic on the same node (RESOLVED: disable firewalld)
Symptom: pods on the same node cannot reach each other. Two signatures, same cause:
- `dial tcp <pod-ip>:<port>: connect: no route to host` (firewalld on the `nftables` backend), or
- `Connection refused` / `ICMP Protocol Unreachable` in ~0ms (firewalld on the `iptables-nft` backend).

Host-to-pod and external ingress work fine throughout -- it specifically hits the FORWARD chain that pod-to-pod transit traverses, where firewalld's default policy REJECTs it.

**`FirewallBackend=iptables` does not fix this** -- it only changes how the reject is written. The service has to be stopped:
```bash
sudo systemctl disable --now firewalld
```
This is Rancher's documented guidance for RKE2/K3s nodes and is what `post_install.sh` does. Full investigation (including the false-negative checks that sent this down a "kernel bug" rabbit hole): `Foo/Pod-to-Pod-Networking-Bug.md`.

### `rke2-uninstall.sh` location differs by install method
The tar.gz-based RKE2 install (older docs, and `get.rke2.io` on non-RPM systems) puts the uninstall script at `/usr/local/bin/rke2-uninstall.sh`. On RHEL 10.2, `get.rke2.io` installs via `dnf`/RPM instead, which puts it at **`/usr/bin/rke2-uninstall.sh`**. Check both if one isn't found.

### Diagnosing "is the app actually listening" -- check IPv6 too
`/proc/net/tcp` only shows IPv4 sockets. Go binaries (including Rancher) commonly call `net.Listen("tcp", ":PORT")`, which binds an **IPv6 dual-stack** socket visible only in `/proc/net/tcp6` -- it still accepts IPv4 connections transparently, but checking only `/proc/net/tcp` (or `ss`/`netstat` without `-6`/both families) will make a genuinely healthy listener look absent. Learned this the hard way after a multi-hour investigation built on an IPv4-only check. Always check both:
```bash
kubectl exec <pod> -- awk '$4=="0A"' /proc/net/tcp    # IPv4 LISTEN
kubectl exec <pod> -- awk '$4=="0A"' /proc/net/tcp6   # IPv6 LISTEN
```

### RKE2 1.35+ defaults to ingress-nginx, not Traefik
Somewhere between RKE2 1.35 and 1.36 the bundled default ingress controller changed. On 1.35.7, `kubectl -n kube-system get svc rke2-traefik` returns `NotFound`; the controller is `rke2-ingress-nginx-controller` instead, deployed as a DaemonSet with `hostPort: 80/443` declared on the container (no separate Service is created by default). If `hostPort` doesn't actually bind on the node (check `sudo ss -tlnp`), the workaround mirrors the Traefik one -- create a `LoadBalancer`-type Service selecting the controller's pods and use the allocated NodePort:
```bash
kubectl -n cattle-system patch ingress rancher --type=merge -p '{"spec":{"ingressClassName":"nginx"}}'
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: rke2-ingress-nginx-controller
  namespace: kube-system
spec:
  type: LoadBalancer
  selector:
    app.kubernetes.io/component: controller
    app.kubernetes.io/instance: rke2-ingress-nginx
    app.kubernetes.io/name: rke2-ingress-nginx
  ports:
  - {name: http, port: 80, targetPort: 80}
  - {name: https, port: 443, targetPort: 443}
EOF
```

### pod-to-pod "Connection refused" in ~0ms (RESOLVED -- same firewalld cause as above)
Was logged here as a distinct unresolved bug: pod A reaches services/hosts on the node fine, the node curls pod B directly and gets `200`, but pod A curling pod B's IP gets `Connection refused` in ~0ms. It blocked Rancher's HA peer mesh and produced a persistent `502` from Traefik to the Rancher backend.

It is **not** distinct -- it is the `iptables-nft`-backend signature of the firewalld FORWARD REJECT covered in the entry above. What actually fixed it was `systemctl disable --now firewalld` (a full service stop). The earlier "tried and didn't fix it" list was misleading: confirming the `iptables` *backend* left the service running, and `nft list ruleset | grep reject` misses firewalld's `xt` REJECT target so the rule looked absent. See `Foo/Pod-to-Pod-Networking-Bug.md`.


