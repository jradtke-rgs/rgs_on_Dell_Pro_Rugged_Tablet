# Troubleshooting

Networking (pod-to-pod communication) Failure
```
  sudo systemctl is-active firewalld
  sudo nft list ruleset | grep -c .        # rule count still present (kube/calico stay)

  kubectl delete pod pod-a pod-b --ignore-not-found
  kubectl run pod-a --image=docker.io/library/nginx:alpine --restart=Never
  kubectl run pod-b --image=docker.io/library/nginx:alpine --restart=Never
  kubectl wait --for=condition=Ready pod/pod-a pod/pod-b --timeout=90s

  IP_B=$(kubectl get pod pod-b -o jsonpath='{.status.podIP}')
  echo "pod-b = $IP_B"

  # host -> pod (expected: 200, always worked)
  curl -s -o /dev/null -w 'host->pod: HTTP %{http_code}\n' --max-time 5 "http://$IP_B/"

  # pod -> pod, same node (the failing case)
  kubectl exec pod-a -- curl -sv --max-time 5 "http://$IP_B/" 2>&1 | tail -15
  kubectl exec pod-a -- ping -c3 -W2 "$IP_B"

```
Output
```
inactive
# Warning: table ip raw is managed by iptables-nft, do not touch!
# Warning: table ip mangle is managed by iptables-nft, do not touch!
# Warning: table ip nat is managed by iptables-nft, do not touch!
# Warning: table ip filter is managed by iptables-nft, do not touch!
# Warning: table ip6 nat is managed by iptables-nft, do not touch!
# Warning: XT target MASQUERADE not found
# Warning: table ip6 filter is managed by iptables-nft, do not touch!
692
pod "pod-a" deleted from default namespace
pod "pod-b" deleted from default namespace
pod/pod-a created
pod/pod-b created
pod/pod-a condition met
pod/pod-b condition met
pod-b = 10.42.0.18
host->pod: HTTP 200
<p>If you see this page, nginx is successfully installed and working.
Further configuration is required for the web server, reverse proxy,
API gateway, load balancer, content cache, or other features.</p>

<p>For online documentation and support please refer to
<a href="https://nginx.org/">nginx.org</a>.<br/>
To engage with the community please visit
<a href="https://community.nginx.org/">community.nginx.org</a>.<br/>
For enterprise grade support, professional services, additional
security features and capabilities please refer to
<a href="https://f5.com/nginx">f5.com/nginx</a>.</p>

<p><em>Thank you for using nginx.</em></p>
</body>
</html>
PING 10.42.0.18 (10.42.0.18): 56 data bytes
64 bytes from 10.42.0.18: seq=0 ttl=63 time=0.054 ms
64 bytes from 10.42.0.18: seq=1 ttl=63 time=0.145 ms
64 bytes from 10.42.0.18: seq=2 ttl=63 time=0.077 ms

--- 10.42.0.18 ping statistics ---
3 packets transmitted, 3 packets received, 0% packet loss
round-trip min/avg/max = 0.054/0.092/0.145 ms
```

> [!NOTE]
> On RKE2/K3s nodes the
>  supported configuration is to disable firewalld entirely (this is Rancher's documented guidance
>  for both distros — firewalld conflicts with the Canal/Flannel dataplane):
>
>  sudo systemctl disable --now firewalld
>
>  If you genuinely need a host firewall on the tablet, drop firewalld and write explicit nftables
>  allows for the pod CIDR (10.42.0.0/16) and service CIDR (10.43.0.0/16), rather than fighting
>  firewalld's zone model.
>
>  post_install.sh should change too — replace the sed/restart block with systemctl disable --now
>  firewalld.
