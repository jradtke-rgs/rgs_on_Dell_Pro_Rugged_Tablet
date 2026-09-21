# README

Testing the deployment of RGS Kubernetes (K3s, RKE2) on a Dell Pro Rugged Tablet 12 running RHEL 10.2.

Performance testing with:
* BaseOS (native test)
* BaseOS + K3s (in container)
* BaseOS + RKE2 (in container)

>[!NOTE]
> I just realized that I am testing with fio and sysbench native on RHEL, but Ubuntu in the container.  Doubtful this would have a measurable performance delta, but I did feel it was worth mentioning.

