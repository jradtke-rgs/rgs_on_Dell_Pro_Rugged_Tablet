# Pod-to-Pod Networking Failure on RKE2/Canal (RHEL 10.2)

**Status:** Unresolved. Root cause isolated below the level of iptables/routing/SELinux — likely a kernel or veth-driver interaction. Recommended for a Red Hat support case (subscription already in place via `post_install.sh`'s `rhc connect`) and/or a rancher/rke2 or projectcalico/calico issue.

## Summary

On a stock RKE2 install with the default Canal CNI (Flannel dataplane + Calico policy), **pods on the same node cannot reach each other** over the pod network. Host-to-pod traffic works perfectly; pod-to-pod traffic is silently converted into a locally-generated `ICMP Protocol Unreachable` by the node itself. This reproduces with zero application software involved — two stock `nginx:alpine` pods are sufficient.

This was discovered while installing Rancher Manager (which needs pod-to-pod connectivity for its HA replica mesh), but Rancher is not implicated — the bug is one layer below it, in the base RKE2/CNI/kernel stack.

## Environment

| Component | Version |
|---|---|
| Hardware | Dell Pro Rugged 12 Tablet (model RA02260) |
| OS | Red Hat Enterprise Linux 10.2 (Coughlan), fresh install |
| Kernel | `6.12.0-211.51.1.el10_2.x86_64` (latest available at time of testing) |
| RKE2 | `v1.36.4+rke2r1` (stable channel) |
| CNI | Canal (default) — Flannel dataplane + Calico policy/Felix |
| Container runtime | containerd `2.3.4-k3s1.36` |
| Cluster topology | Single node, embedded etcd |
| SELinux | Enforcing |
| firewalld | `FirewallBackend=iptables` (explicitly set; see note below) |

**Note on firewalld:** RHEL 10 defaults `firewalld` to the `nftables` backend, which is independently known to conflict with Canal's iptables-nft-programmed rules (symptom: `no route to host` between pods). That issue was found and fixed first (`FirewallBackend=iptables`, confirmed via `nft` counters that traffic was accepted). **The bug described in this document is a separate, distinct failure** that persists after that fix, is confirmed present on a from-scratch OS install with no more firewalld involvement, and shows a different error signature (`Connection refused` / `ICMP Protocol Unreachable`, not `no route to host`).

## Reproduction (minimal, no Rancher required)

```bash
kubectl run pod-a --image=docker.io/library/nginx:alpine --restart=Never
kubectl run pod-b --image=docker.io/library/nginx:alpine --restart=Never
kubectl wait --for=condition=Ready pod/pod-a pod/pod-b --timeout=90s

IP_B=$(kubectl get pod pod-b -o jsonpath='{.status.podIP}')

# Works: host -> pod
curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://$IP_B/
# HTTP 200

# Fails: pod -> pod (same node)
kubectl exec pod-a -- curl -v --max-time 5 http://$IP_B/
# * Trying <IP_B>:80...
# * connect to <IP_B> port 80 from <IP_A> port NNNNN failed: Connection refused
# * Failed to connect to <IP_B>:80 after 0 ms: Could not connect to server

kubectl exec pod-a -- ping -c 3 -W 2 $IP_B
# 100% packet loss -- same failure over ICMP, ruling out anything TCP-specific
```

The `Connection refused` arrives in **~0ms** — too fast to be a real round trip to the destination — which was the first hint this was being generated locally rather than reflecting real network loss.

## Root-cause isolation (packet-level evidence)

Simultaneous `tcpdump` on both pods' host-side veth interfaces during one ICMP echo:

```
# Source pod's veth (cali5e1c4d6c68c) -- egress captured:
18:49:04.272092 IP (tos 0x0, ttl 64, ..., proto ICMP (1), length 84)
    10.42.0.13 > 10.42.0.14: ICMP echo request, id 80, seq 0, length 64
18:49:04.272171 IP (tos 0xc0, ttl 64, ..., proto ICMP (1), length 112)
    10.10.12.185 > 10.42.0.13: ICMP 10.42.0.14 protocol 1 port 13018 unreachable, length 92
	IP (tos 0x0, ttl 63, ..., proto ICMP (1), length 84)
    10.42.0.13 > 10.42.0.14: ICMP echo request, id 80, seq 0, length 64

# Destination pod's veth (cali2f5353dd8c5) -- captured simultaneously:
(0 packets captured)
```

Key facts this establishes:

1. **The packet genuinely leaves the source pod** — captured on the wire at its own veth.
2. **The packet never arrives at the destination pod's veth** — zero packets captured there, in a simultaneous capture.
3. **The node itself (`10.10.12.185`) generates the `ICMP Protocol Unreachable`** reply, using its own IP as source — this is standard behavior for a host acting as the forwarding router when it cannot complete delivery.
4. **The embedded original packet inside the ICMP error shows `ttl 63`**, one less than the `ttl 64` it left the source pod with. TTL is only decremented during an actual IP forwarding step — meaning the kernel *did* make a forwarding decision and process the packet as transit traffic, then failed at the final delivery/transmission step rather than rejecting it outright at ingress.

This "forwarding decision made, TTL decremented, then bounced as Protocol Unreachable instead of actually transmitted" pattern is not something `iptables`/`nftables` rule inspection or standard routing-table checks can explain — every layer that a REJECT rule or misroute could occur at was individually checked and cleared (below).

## Causes ruled out, with evidence

| Hypothesis | Check performed | Result |
|---|---|---|
| firewalld/nftables backend blocking FORWARD | `firewall-cmd --state`, backend config | Already on `iptables` backend, confirmed |
| Explicit nftables REJECT rule | `nft list ruleset \| grep -i 'proto-unreachable\|reject'` across full ruleset | No matches anywhere |
| Calico/Canal policy chains dropping traffic | Live packet-counter diff on `FORWARD`, `cali-FORWARD`, `cali-to-wl-dispatch`, `cali-tw-<iface>` before/after reproducing | Every chain's counter **incremented** (packet accepted), none show drops |
| `cali-cidr-block` / `cali-to-hep-forward` chains | `nft list chain ip filter cali-cidr-block` / `cali-to-hep-forward` | Both chains are **empty** |
| Kubernetes NetworkPolicy | `kubectl get networkpolicy -A` | Only one policy exists, in an unrelated namespace, `POD-SELECTOR: <none>` (allow-all) |
| Incorrect routing table | `ip route get <dest-pod-ip>` | Resolves correctly to the destination's veth via the `main` table |
| `local` routing table conflict | `ip route show table local`, `ip rule show` | Only contains flannel's own VTEP address (`10.42.0.0`), does not match any pod IP |
| Stale/broken ARP/neighbor entry | `ip neigh show` for destination pod IP | Valid entry present (`STALE`, which is normal and does not block transmission) |
| Reverse-path filtering (`rp_filter`) | Found `net.ipv4.conf.all.rp_filter=0` but `default.rp_filter=1` (a known Linux gotcha where `all` doesn't retroactively lower already-created interfaces). Set `rp_filter=0` directly on every `cali*` interface. | No change — failure persists |
| SELinux | `getenforce` (Enforcing), `ausearch -m avc -ts recent` | Zero AVC denials |
| IP forwarding disabled | `sysctl net.ipv4.ip_forward` | `= 1` (enabled) |
| Stale kernel/conntrack state from repeated installs | Full node reboot; separately, a **complete OS reinstall** | Reproduces identically on a from-scratch RHEL 10.2 install |
| CNI (canal) pod itself unhealthy/stale | `kubectl delete pod -l k8s-app=canal` and let it recreate | No change |
| Kernel out of date | `sudo dnf check-update kernel` | Already on latest available (`6.12.0-211.51.1.el10_2`) |
| Rancher-specific bug | Reproduced with two stock `nginx:alpine` pods, no Rancher/Helm/cert-manager involved | Confirmed not Rancher-specific |

## Suggested next steps

1. **File with Red Hat**: this environment has an active subscription (`rhc connect` in `post_install.sh`). The kernel-level "forwards then bounces as Protocol Unreachable" behavior is squarely in kernel networking / veth driver territory and is the most likely place for someone with kernel source access and `crash`/`ftrace` tooling to make progress quickly.
2. **File against `rancher/rke2` and/or `projectcalico/calico`**: include the exact repro steps above (two `nginx:alpine` pods, `curl`/`ping` between them). Worth checking whether this is a known issue with Canal specifically on very new RHEL kernels.
3. **Try an alternate CNI** (e.g., installing RKE2 with `cni: calico` full-Calico instead of Canal, or `cni: cilium`) as an empirical test — if pod-to-pod works under a different CNI on the same kernel, that strongly implicates Canal's specific Flannel+Calico interaction rather than the kernel itself.
4. **Kernel-level tracing** if pursuing further in-house: `bpftrace`/`ftrace` on the forwarding path (`ip_forward()`, veth `xmit`, and the `netfilter` hooks) during a live reproduction would show exactly which kernel function decides to bounce the packet instead of transmitting it.

## Timeline note

This was found during a session that also chased (and ruled out) several red herrings before isolating the above — including a self-inflicted diagnostic error (checking only `/proc/net/tcp`, which is IPv4-only, when the relevant listeners were IPv6 dual-stack sockets visible only in `/proc/net/tcp6`) that had earlier and incorrectly implicated Rancher's application code and Rancher/Kubernetes version compatibility. Both are explicitly ruled out above; this document reflects the corrected, packet-verified root cause only.
