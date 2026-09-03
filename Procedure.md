# Kubernetes Performance Benchmark on Dell Pro Rugged 12 (RA02260)

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

**CPU Benchmark (Calculates primes up to 20000 across 4 threads):**
```bash
echo "--- CPU TEST ---" | tee ~/Results/RHEL-10.2/sysbench-cpu-mem.out
sysbench cpu --cpu-max-prime=20000 --threads=4 run | tee -a ~/Results/RHEL-10.2/sysbench-cpu-mem.out
```
*(Record the "events per second" and "total time" in the Results Table)*

**Memory Benchmark (Tests read/write speed):**
```bash
echo "--- MEMORY TEST ---" | tee -a ~/Results/RHEL-10.2/sysbench-cpu-mem.out
sysbench memory --memory-block-size=1K --memory-total-size=10G --threads=4 run | tee -a ~/Results/RHEL-10.2/sysbench-cpu-mem.out
```
*(Record the "MiB transferred" and "Total operations" in the Results Table)*

---

## Phase 2: K3s Evaluation

### 1. K3s Installation
Since K3s is a single-binary Kubernetes distribution, installation is very quick.  I did not pin to a specific version - if I was doing this task repeatedly and over time, I would probably either pin, or record the results with the version number as a reference.
# Install K3s
```bash
curl -sfL https://get.k3s.io | sh -
mkdir ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $(whoami) ~/.kube/config; chmod 0664 ~/.kube/config; 
echo "export KUBECONFIG=~/.kube/config" | tee -a ~/.bashrc
. ~/.bashrc
```

# Verify node is ready
```bash
k3s kubectl get nodes
```

### 2. Run K3s Benchmarks
We will deploy a Kubernetes Job that spins up an Ubuntu container, installs sysbench, and runs the same tests.

Create a file named `k3s-bench.yaml`:yaml
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

Apply and read the logs:
```bash
kubectl apply -f k3s-bench.yaml
```

# Wait for the job to complete, then view the results:
```bash
k3s kubectl logs job/benchmark-job-cpu-mem | tee ~/Results/RHEL-10.2-K3s/sysbench-cpu-mem.out
```
*(Record the results in the Results Table)*

# Uninstall K3s
```bash
 sudo /usr/local/bin/k3s-uninstall.sh
```

---
## Phase 3: RKE2 Evaluation

### 1. RKE2 Installation
**Important:** Wipe the OS and perform a fresh install of RHEL 10.2 to ensure there is no artifacting from K3s.
# Install RKE2 (Rancher Kubernetes Engine 2)
```bash
curl -sfL https://get.rke2.io | sudo sh -
```
# Enable and start the RKE2 server service
```bash
sudo systemctl enable rke2-server.service
sudo systemctl start rke2-server.service
```
# Symlink kubectl for ease of use
```bash
sudo ln -s /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl
sudo cat /etc/rancher/rke2/rke2.yaml | tee ~/.kube/config
export KUBECONFIG=~/.kube/config
```
# Verify node is ready
```bash
kubectl get nodes
```
### 2. Run RKE2 Benchmarks
Deploy the exact same job used in Phase 2.
```bash
kubectl apply -f k3s-bench.yaml
```
# Wait for the job to complete, then view the results:
```bash
kubectl logs job/benchmark-job-cpu-mem  | tee ~/Results/RHEL-10.2-RKE2/sysbench-cpu-mem.out
```
*(Record the results in the Results Table)*

---

## Results Tracking Matrix

### CPU Performance (Higher Events/sec is better)
| Environment | Events per Second | Total Time (s) | 95th Percentile Latency (ms) |
|:-------------|:-------------------|:----------------|:------------------------------|
| RHEL 10.2 (Baseline) | | | |
| K3s Container | | | |
| RKE2 Container | | | |

### Memory Performance (Higher MiB/sec is better)
| Environment | Total Operations | Transfer Rate (MiB/sec) | 95th Percentile Latency (ms) |
|:-------------|:------------------|:-------------------------|:------------------------------|
| RHEL 10.2 (Baseline) | | | |
| K3s Container | | | |
| RKE2 Container | | | |

### Notes / Observations
* **OS Footprint:** Note the idle RAM and CPU usage of `htop` right after fresh boot for each iteration.
* **Boot Time:** Note how long it takes for the node to reach `Ready` status in K3s vs RKE2.
