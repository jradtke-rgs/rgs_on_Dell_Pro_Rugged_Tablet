# Troubleshooting

## Pod-to-pod networking failure (same node) — RESOLVED: disable firewalld

**Symptom.** Host-to-pod traffic works. Pod-to-pod traffic on the same node fails — `curl` between two pods returns `Connection refused` in ~0 ms, `ping` shows 100% loss. On the older `nftables` firewalld backend the same failure shows as `no route to host`. Breaks anything needing pod-to-pod: Rancher's HA replica mesh, ingress → backend Service, CoreDNS in some paths.

**Cause.** firewalld. Its `filter` FORWARD chain REJECTs forwarded pod-to-pod transit traffic that no zone rule permits; the node emits a locally-sourced ICMP unreachable carrying the (already TTL-decremented) packet. Changing `FirewallBackend` from `nftables` to `iptables` does **not** fix this — it only changes how the reject is written. The `firewalld` service has to be stopped.

Full write-up of the investigation that got here: [`Pod-to-Pod-Networking-Bug.md`](./Pod-to-Pod-Networking-Bug.md).

**Fix.**

```bash
sudo systemctl disable --now firewalld
```

This is Rancher's documented guidance for RKE2 and K3s nodes. Applied up front in [`../Scripts/post_install.sh`](../Scripts/post_install.sh).

### Verification

```bash
sudo systemctl is-active firewalld            # -> inactive
sudo nft list ruleset | grep -c .             # CNI/kube rules still present

kubectl delete pod pod-a pod-b --ignore-not-found
kubectl run pod-a --image=docker.io/library/nginx:alpine --restart=Never
kubectl run pod-b --image=docker.io/library/nginx:alpine --restart=Never
kubectl wait --for=condition=Ready pod/pod-a pod/pod-b --timeout=90s

IP_B=$(kubectl get pod pod-b -o jsonpath='{.status.podIP}')
echo "pod-b = $IP_B"

# host -> pod (always worked)
curl -s -o /dev/null -w 'host->pod: HTTP %{http_code}\n' --max-time 5 "http://$IP_B/"

# pod -> pod, same node (was failing)
kubectl exec pod-a -- curl -sv --max-time 5 "http://$IP_B/" 2>&1 | tail -15
kubectl exec pod-a -- ping -c3 -W2 "$IP_B"
```

Passing output (firewalld stopped):

```
inactive
692
pod-b = 10.42.0.18
host->pod: HTTP 200
<p>If you see this page, nginx is successfully installed and working. ...</p>
PING 10.42.0.18 (10.42.0.18): 56 data bytes
64 bytes from 10.42.0.18: seq=0 ttl=63 time=0.054 ms
64 bytes from 10.42.0.18: seq=1 ttl=63 time=0.145 ms
64 bytes from 10.42.0.18: seq=2 ttl=63 time=0.077 ms
--- 10.42.0.18 ping statistics ---
3 packets transmitted, 3 packets received, 0% packet loss
round-trip min/avg/max = 0.054/0.092/0.145 ms
```

The `# Warning: table ip … is managed by iptables-nft` / `# Warning: XT target MASQUERADE not found` lines from `nft list ruleset` are expected noise from the iptables-nft compat shim and are unrelated to the fix.
