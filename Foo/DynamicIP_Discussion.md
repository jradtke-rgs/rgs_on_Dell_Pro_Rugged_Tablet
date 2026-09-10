Yes — that's a sound pattern, and it's essentially a more deliberate version of the dummy-interface approach I mentioned, but you're right that it needs a NAT/redirect layer to actually be reachable. Let me walk through why it works, what specifically needs the proxy vs. what doesn't, and the gotchas.

## Why you need this at all

`kube-apiserver` (and the RKE2 supervisor) typically bind `0.0.0.0`, so in isolation they're already reachable on *any* local address, including the DHCP IP. The reason you can't just rely on that directly is **routability, not listening**: 172.16.0.10 lives on a dummy interface local to the laptop — nothing else on the 10.0.0.0/24 segment has a route to it. External clients can only ever reach the box via whatever address the LAN actually routes to (the DHCP IP). So the DNAT's job is to bridge "the only address the outside world can dial" to "the stable address RKE2 is internally anchored to."

## The pieces

**1. Dummy interface, stable IP**
```bash
ip link add dummy0 type dummy
ip addr add 172.16.0.10/32 dev dummy0
ip link set dummy0 up
```

**2. RKE2 config anchored to it**
```yaml
node-ip: 172.16.0.10
tls-san:
  - 172.16.0.10
  - edge-node.local   # see hostname note below
```

**3. DNAT rule — match on port only, not source IP or interface**

This is the important refinement: don't scope the rule to the current DHCP IP or a specific NIC name (wlan0 vs eth0 vs enp0s...), or you're back to needing a dispatcher script every time it changes. Match purely on destination port:

```bash
sysctl -w net.ipv4.ip_forward=1
iptables -t nat -A PREROUTING -p tcp --dport 6443 -j DNAT --to-destination 172.16.0.10:6443
```

One subtlety worth knowing: because 172.16.0.10 is *local* to this same host (on dummy0), after the DNAT rewrite the kernel's routing decision sees it as a local address and delivers via the **INPUT** chain, not FORWARD — this is a "hairpin"/local-redirect, not true forwarding to another box. So if you have a default-DROP INPUT policy, allow it there:
```bash
iptables -A INPUT -d 172.16.0.10 -p tcp --dport 6443 -j ACCEPT
```

Persist with `iptables-save`/nftables or a small systemd unit that applies it on boot.

## What doesn't need this at all

RKE2's bundled ingress-nginx normally runs with `hostNetwork: true`, so it's already listening on 0.0.0.0:80/443 regardless of which IP a client hits. **Rancher's UI traffic typically doesn't need the DNAT trick** — only the components whose identity is tied to `node-ip`/cert SANs do (apiserver on 6443, supervisor on 9345 if you're using HA-style joins). Worth confirming your ingress DaemonSet is indeed hostNetwork before assuming you need to redirect 80/443 too — it saves you rules you don't need.

## The TLS SAN catch

DNAT solves *routability*, but the TLS handshake is validated against whatever address/hostname the **client actually typed**, not the post-NAT destination. If someone runs `kubectl` against `https://10.0.0.55:6443` (today's DHCP IP), the cert needs `10.0.0.55` in its SAN list — and that breaks the moment DHCP hands out a new address.

The clean fix: don't have clients dial an IP at all. Use a stable name — mDNS/avahi (`edge-node.local`), a DDNS record, or even a static `/etc/hosts` entry on known management workstations — put *that* in `tls-san` once, and let DNS/mDNS resolution track wherever the current DHCP IP is. Kubeconfig points at `https://edge-node.local:6443` forever; the DNAT handles getting the packet to the right place once it lands.

## Where this approach stops working

This solves "DHCP renews within the same subnet." It does **not** solve the laptop roaming to a genuinely different network (new building, cellular hotspot, different WiFi entirely) — in that case there's no path back to the old DHCP IP for anyone who cached it, mDNS `.local` names won't resolve across routed networks, and you're fully into the mesh-VPN territory (Tailscale/WireGuard) from the earlier answer. If "occasionally changes" means IP churn on one network, your design is the right, minimal-dependency answer. If it also means "sometimes shows up on a completely different network," I'd pair this with a mesh overlay rather than trying to extend the DNAT/DDNS approach to cover that case too.
