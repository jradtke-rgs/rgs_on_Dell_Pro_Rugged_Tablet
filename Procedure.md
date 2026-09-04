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
echo "--- CPU TEST ---" | tee ~/Results/RHEL-10.2/sysbench-cpu-mem.out
sysbench cpu --cpu-max-prime=20000 --threads=4 run | tee -a ~/Results/RHEL-10.2/sysbench-cpu-mem.out
```
*(Record the "events per second" and "total time" in the Results Table)*

#### Memory Benchmark (Tests read/write speed)
```bash
echo "--- MEMORY TEST ---" | tee -a ~/Results/RHEL-10.2/sysbench-cpu-mem.out
sysbench memory --memory-block-size=1K --memory-total-size=10G --threads=4 run | tee -a ~/Results/RHEL-10.2/sysbench-cpu-mem.out
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

**Prerequisite:** `post_install.sh` sets firewalld's backend to `iptables` before this runs. If you skip that step (or restore a snapshot from before it existed), do it before installing RKE2 -- otherwise pod-to-pod traffic gets silently blocked once you're running more than a single-pod workload (see Troubleshooting).

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

### 2. Add the Rancher and Jetstack (cert-manager) Helm repos
```bash
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
helm repo add jetstack https://charts.jetstack.io
helm repo update
```

### 3. Install cert-manager
Rancher requires cert-manager for TLS unless you bring your own certificates.
```bash
kubectl create namespace cert-manager
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --set crds.enabled=true
```

#### Verify cert-manager pods are running
```bash
kubectl get pods --namespace cert-manager
```

### 4. Install Rancher Manager
Replace `rancher.example.local` with the hostname/IP you'll use to reach the UI, and choose a real bootstrap password.
NOTE:  I created a DNS entry for this exercise

```bash
kubectl create namespace cattle-system
helm install rancher rancher-latest/rancher \
  --namespace cattle-system \
  --set hostname=rancher-test.community.kubernerdes.com \
  --set bootstrapPassword=admin123
```

#### Wait for the Rancher deployment to roll out
```bash
kubectl -n cattle-system rollout status deploy/rancher
```

### 5. Expose Traefik on the node (required for external access)
**Confirmed on a from-scratch install** (not just this one instance): RKE2 v1.36.4+rke2r1 ships `rke2-traefik` as `type: ClusterIP` by default -- nothing binds the node's real interface out of the box, so the ingress/DNS/cert setup above is correct but unreachable from a browser until you patch it. RKE2's built-in ServiceLB is expected to pick up a `LoadBalancer`-type Service and bind the node automatically; on this hardware it hasn't (no `svclb-*` pod appears), but the patch still gets you a working NodePort even without it:
```bash
kubectl -n kube-system patch svc rke2-traefik -p '{"spec":{"type":"LoadBalancer"}}'
kubectl -n kube-system get svc rke2-traefik
```
Note the allocated NodePort for `443` (e.g. `443:32051/TCP`) in the output. If an `EXTERNAL-IP` never appears (stays `<pending>`) and no `svclb-rke2-traefik-*` pod shows up under `kubectl -n kube-system get pods`, ServiceLB isn't reconciling on this box -- access via the NodePort instead: `https://<hostname>:<nodeport>/`.

### 6. Access Rancher
Browse to `https://rancher-test.community.kubernerdes.com` (or `https://<hostname-or-IP>:<nodeport>/`, per step 5) and log in using the bootstrap password set above. You'll be prompted to set a new admin password and confirm the server URL on first login.

> [!WARNING]
> **Known issue, not yet resolved:** After a fresh install, all 3 Rancher replica pods can sit for 15+ minutes with *neither* port 80 nor 443 bound inside the container (confirmed via `/proc/<pid>/net/tcp` on the node), even though `kubectl get pods` reports `1/1 Running` and a stable HA leader lease exists. Logs show continuous `Failed to connect to peer wss://... connect: connection refused` between replicas and repeated `Active TLS secret cattle-system/tls-rancher-internal` regeneration. Root cause not yet identified -- ruled out so far: firewalld/CNI blocking (fixed separately, confirmed via nft counters), host memory pressure (30Gi RAM, only ~8Gi used), and CCM instability (its 8 restarts lined up with the etcd `--cluster-reset` timestamp, not with this). If you hit this, check `kubectl -n cattle-system logs deploy/rancher --tail=30` and `/proc/<pid>/net/tcp` on the node for each `rancher` process before assuming it's just still starting up.

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

### firewalld nftables backend blocks pod-to-pod traffic
`post_install.sh` now sets `FirewallBackend=iptables` up front, so this shouldn't recur -- but if you're troubleshooting an older/skipped setup: symptom is `dial tcp <pod-ip>:<port>: connect: no route to host` between pods **on the same node** (external ingress traffic and node-to-pod traffic can work fine while this is broken -- it specifically hits the FORWARD chain that pod-to-pod traffic traverses). Confirm via `sudo grep FirewallBackend /etc/firewalld/firewalld.conf`, then:
```bash
sudo sed -i 's/^FirewallBackend=.*/FirewallBackend=iptables/' /etc/firewalld/firewalld.conf
sudo systemctl restart firewalld
```

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

### UNRESOLVED: pod-to-pod "Connection refused" (not "no route to host")
Distinct from the firewalld issue above. Symptom: pod A can reach a service/host on the node fine, and the node can curl pod B directly and get a real HTTP response, but pod A curling pod B's IP directly gets `Connection refused` in ~0ms -- too fast to be a real network round trip. This blocks Rancher's internal HA peer mesh and breaks ingress-nginx/Traefik reaching the Rancher backend Service (manifests as a persistent `502`) even though Rancher itself is confirmed healthy (`curl` to the pod IP directly, from the node, returns `200`).

Tried and **did not** fix it:
- Confirming firewalld is on the `iptables` backend (it was)
- Restarting the CNI pod (`kubectl -n kube-system delete pod -l k8s-app=canal`)
- A full node reboot

Encountered after a day of repeated full RKE2 install/uninstall cycles on the same RHEL install -- unconfirmed whether a from-scratch OS install avoids it. If it recurs: next step would be packet-level tracing (`tcpdump` on the relevant `cali*` veth plus `conntrack -L` while reproducing) rather than another config-level guess, since nft counters show the traffic being *accepted*, not dropped, which contradicts the symptom.


