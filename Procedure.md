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
2. Update the system and install benchmarking tools:
      sudo dnf update -y
   sudo dnf install -y epel-release
   sudo dnf install -y sysbench fio
   ```

### 2. Run Baseline Benchmarks

**CPU Benchmark (Calculates primes up to 20000 across 4 threads):**bash
sysbench cpu --cpu-max-prime=20000 --threads=4 run
*(Record the "events per second" and "total time" in the Results Table)*

**Memory Benchmark (Tests read/write speed):**bash
sysbench memory --memory-block-size=1K --memory-total-size=10G --threads=4 run
*(Record the "MiB transferred" and "Total operations" in the Results Table)*

---

## Phase 2: K3s Evaluation

### 1. K3s Installation
Since K3s is a single-binary Kubernetes distribution, installation is very quick.bash
# Install K3s
curl -sfL https://get.k3s.io | sh -

# Verify node is ready
sudo k3s kubectl get nodes

### 2. Run K3s Benchmarks
We will deploy a Kubernetes Job that spins up an Ubuntu container, installs sysbench, and runs the same tests.

Create a file named `k3s-bench.yaml`:yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: benchmark-job-cpu-mem
spec:
  template:
    spec:
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

Apply and read the logs:bash
sudo k3s kubectl apply -f k3s-bench.yaml

# Wait for the job to complete, then view the results:
sudo k3s kubectl logs job/benchmark-job-cpu-mem
*(Record the results in the Results Table)*

---

## Phase 3: RKE2 Evaluation

### 1. RKE2 Installation
**Important:** Wipe the OS and perform a fresh install of RHEL 10.2 to ensure there is no artifacting from K3s.
bash
# Install RKE2 (Rancher Kubernetes Engine 2)
curl -sfL https://get.rke2.io | sudo sh -

# Enable and start the RKE2 server service
sudo systemctl enable rke2-server.service
sudo systemctl start rke2-server.service

# Symlink kubectl for ease of use
sudo ln -s /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

# Verify node is ready
kubectl get nodes

### 2. Run RKE2 Benchmarks
Deploy the exact same job used in Phase 2.
bash
kubectl apply -f k3s-bench.yaml

# Wait for the job to complete, then view the results:
kubectl logs job/benchmark-job-cpu-mem
```
*(Record the results in the Results Table)*

---

## Results Tracking Matrix

### CPU Performance (Higher Events/sec is better)
| Environment | Events per Second | Total Time (s) | 95th Percentile Latency (ms) |
|-------------|-------------------|----------------|------------------------------|
| RHEL 10.2 (Baseline) | | | |
| K3s Container | | | |
| RKE2 Container | | | |

### Memory Performance (Higher MiB/sec is better)
| Environment | Total Operations | Transfer Rate (MiB/sec) | 95th Percentile Latency (ms) |
|-------------|------------------|-------------------------|------------------------------|
| RHEL 10.2 (Baseline) | | | |
| K3s Container | | | |
| RKE2 Container | | | |

### Notes / Observations
* **OS Footprint:** Note the idle RAM and CPU usage of `htop` right after fresh boot for each iteration.
* **Boot Time:** Note how long it takes for the node to reach `Ready` status in K3s vs RKE2.