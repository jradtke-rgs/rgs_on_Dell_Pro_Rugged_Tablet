# Pod-to-Pod Networking Failure on RKE2/Canal (RHEL 10.2) — RESOLVED (firewalld)

**Status:** RESOLVED (2026-09-05). Root cause: **firewalld**. Its `filter` FORWARD chain REJECTs forwarded pod-to-pod traffic, and the node returns a locally-generated ICMP unreachable. Setting `FirewallBackend=iptables` while leaving the service *running* is **not** sufficient — the service itself has to be stopped/disabled. `sudo systemctl disable --now firewalld` (Rancher's documented guidance for RKE2 and K3s nodes) fixes it completely and permanently. The rest of this document is retained as a post-mortem — the packet-level evidence below was consistent with firewalld the whole time, and the "Causes ruled out" table records which checks produced false negatives.

## Resolution

After `sudo systemctl stop firewalld` (a full service stop, not the earlier `FirewallBackend` swap), pod-to-pod works immediately — verified with the standard two-`nginx:alpine`-pod repro:

```
pod-b = 10.42.0.18
host->pod: HTTP 200
pod-a -> pod-b: HTTP 200 (nginx welcome page returned)
ping 10.42.0.18: 3 packets transmitted, 3 received, 0% packet loss, rtt ~0.09 ms
```

Why the earlier "fix" didn't hold: `FirewallBackend=iptables` only changes *how* firewalld programs its rules (iptables-nft vs. the nft backend). It does not stop firewalld from installing its own jump into the FORWARD chain, and that chain's default policy REJECTs forwarded traffic that no zone rule permits — which is all pod-to-pod transit traffic. With the nft backend the reject surfaced as `no route to host`; with the iptables-nft backend and the service still running it surfaced as `Connection refused` / `ICMP Protocol Unreachable`. Same cause, two signatures. Stopping the service removes the jump entirely and the CNI's own rules (which do permit the traffic) are all that remain.

The "reproduces on a from-scratch install with no firewalld involvement" claim below was wrong: RHEL enables firewalld by default, so the fresh install still had it running. "No firewalld involvement" was assumed, never verified by stopping the service.

**Fix, applied in `Scripts/post_install.sh`:**

```bash
sudo systemctl disable --now firewalld
```

## Summary

On a stock RKE2 install with the default Canal CNI (Flannel dataplane + Calico policy), with **firewalld running** (RHEL default), **pods on the same node could not reach each other** over the pod network. Host-to-pod traffic worked perfectly; pod-to-pod traffic was silently converted into a locally-generated `ICMP Protocol Unreachable` by the node itself. This reproduced with zero application software involved — two stock `nginx:alpine` pods were sufficient.

This was discovered while installing Rancher Manager (which needs pod-to-pod connectivity for its HA replica mesh), but Rancher is not implicated. The cause was firewalld's FORWARD-chain REJECT (see Resolution above); `systemctl disable --now firewalld` fixes it. Everything below this line is the original investigation, kept as a post-mortem.

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
| firewalld | During the bug: **running**, `FirewallBackend=iptables`. Fix: **disabled** (`systemctl disable --now firewalld`). See note below. |

**Note on firewalld:** ~~RHEL 10 defaults `firewalld` to the `nftables` backend, which is independently known to conflict with Canal's iptables-nft-programmed rules (symptom: `no route to host` between pods). That issue was found and fixed first (`FirewallBackend=iptables`, confirmed via `nft` counters that traffic was accepted). **The bug described in this document is a separate, distinct failure** that persists after that fix, is confirmed present on a from-scratch OS install with no more firewalld involvement, and shows a different error signature (`Connection refused` / `ICMP Protocol Unreachable`, not `no route to host`).~~

**Correction (see Resolution above):** this was not a separate failure. `FirewallBackend=iptables` changes only *how* firewalld writes its rules, not *whether* it jumps into the FORWARD chain. The `no route to host` and `Connection refused` / `ICMP Protocol Unreachable` signatures are the same firewalld REJECT seen through two different backends. Stopping the `firewalld` service — which the `FirewallBackend` change never did — is what actually fixes it. The fresh-install test still had firewalld running (RHEL default).

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

This "forwarding decision made, TTL decremented, then bounced as Protocol Unreachable instead of actually transmitted" pattern was read at the time as something rule inspection couldn't explain. In hindsight it is exactly what a REJECT in the `filter` FORWARD chain does: routing (and the TTL decrement) happens first, the REJECT verdict is applied at the FORWARD hook, and the kernel emits a locally-sourced ICMP unreachable carrying the decremented packet. The rule *was* there — firewalld's — the inspection below just missed it (see next section).

## Causes ruled out, with evidence

| Hypothesis | Check performed | Result |
|---|---|---|
| firewalld/nftables backend blocking FORWARD | `firewall-cmd --state`, backend config | **FALSE NEGATIVE.** Confirmed "already on `iptables` backend" and stopped there. The backend was never the issue — firewalld *running at all* was. `systemctl stop firewalld` was not tried until the follow-up session, and it fixed it. |
| Explicit nftables REJECT rule | `nft list ruleset \| grep -i 'proto-unreachable\|reject'` across full ruleset | **FALSE NEGATIVE.** With `FirewallBackend=iptables`, firewalld's reject is an `xt` REJECT target, which `grep -i reject` on `nft list ruleset` does not reliably surface. The rule was present in firewalld's FORWARD jump the whole time. |
| Calico/Canal policy chains dropping traffic | Live packet-counter diff on `FORWARD`, `cali-FORWARD`, `cali-to-wl-dispatch`, `cali-tw-<iface>` before/after reproducing | Every chain's counter **incremented** (packet accepted), none show drops |
| `cali-cidr-block` / `cali-to-hep-forward` chains | `nft list chain ip filter cali-cidr-block` / `cali-to-hep-forward` | Both chains are **empty** |
| Kubernetes NetworkPolicy | `kubectl get networkpolicy -A` | Only one policy exists, in an unrelated namespace, `POD-SELECTOR: <none>` (allow-all) |
| Incorrect routing table | `ip route get <dest-pod-ip>` | Resolves correctly to the destination's veth via the `main` table |
| `local` routing table conflict | `ip route show table local`, `ip rule show` | Only contains flannel's own VTEP address (`10.42.0.0`), does not match any pod IP |
| Stale/broken ARP/neighbor entry | `ip neigh show` for destination pod IP | Valid entry present (`STALE`, which is normal and does not block transmission) |
| Reverse-path filtering (`rp_filter`) | Found `net.ipv4.conf.all.rp_filter=0` but `default.rp_filter=1` (a known Linux gotcha where `all` doesn't retroactively lower already-created interfaces). Set `rp_filter=0` directly on every `cali*` interface. | No change — failure persists |
| SELinux | `getenforce` (Enforcing), `ausearch -m avc -ts recent` | Zero AVC denials |
| IP forwarding disabled | `sysctl net.ipv4.ip_forward` | `= 1` (enabled) |
| Stale kernel/conntrack state from repeated installs | Full node reboot; separately, a **complete OS reinstall** | Reproduces identically on a from-scratch RHEL 10.2 install — **because RHEL enables firewalld by default and it was never stopped on that install either.** Not evidence against firewalld. |
| CNI (canal) pod itself unhealthy/stale | `kubectl delete pod -l k8s-app=canal` and let it recreate | No change |
| Kernel out of date | `sudo dnf check-update kernel` | Already on latest available (`6.12.0-211.51.1.el10_2`) |
| Rancher-specific bug | Reproduced with two stock `nginx:alpine` pods, no Rancher/Helm/cert-manager involved | Confirmed not Rancher-specific |

## Lessons

1. **"Is the service running?" beats "how is the service configured?"** The whole detour came from confirming firewalld's *backend* and treating that as having cleared firewalld. `systemctl stop firewalld` is one command and should have been the first thing tried, not the last.
2. **Rule-inspection greps are only as good as the backend they assume.** `nft list ruleset | grep reject` misses `xt` REJECT targets installed via iptables-nft. When in doubt, `iptables-save`/`nft list ruleset` in full, and diff FORWARD-chain packet counters with the service stopped vs. running.
3. **A locally-generated ICMP unreachable with a decremented TTL is a REJECT signature, not a kernel bug.** Route lookup and TTL decrement precede the FORWARD hook; a REJECT there produces exactly this.
4. **"Reproduces on a fresh install" only rules out state you actually removed.** firewalld is on by default in RHEL; a fresh install doesn't clear it.
5. **Rancher's own docs say to disable firewalld on RKE2/K3s nodes.** Following that from the start would have skipped this entirely.

## Timeline note

This was found during a session that also chased (and ruled out) several red herrings before isolating the above — including a self-inflicted diagnostic error (checking only `/proc/net/tcp`, which is IPv4-only, when the relevant listeners were IPv6 dual-stack sockets visible only in `/proc/net/tcp6`) that had earlier and incorrectly implicated Rancher's application code and Rancher/Kubernetes version compatibility. The "kernel / veth-driver" conclusion this document originally reached was also wrong — see Resolution. Both are corrected above.
