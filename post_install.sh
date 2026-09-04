#!/bin/bash

# The following are tasks intended for the Base OS
# Specific testing is located in [Procedure.md](./Procedure.md)

# You will need to login to the device at the terminal
sudo systemctl enable sshd --now
# You can now ssh in to the host
# Also - while you are logged in disable the "Automatic Power Saver" - click on Upper Right, the gear (for settings), type "Power" and click on the choice that appears

DAUSER=mansible
echo "$DAUSER ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/$DAUSER-nopasswd-all


# firewalld on RHEL 10 defaults to the nftables backend, which conflicts with
# RKE2's Canal CNI (flannel + Calico policy, which programs iptables-nft rules
# for pod-to-pod traffic). Left as nftables, firewalld's own FORWARD-chain
# rules intercept/drop pod-to-pod traffic even though the kernel routing table
# is correct -- symptom is "no route to host" between pods on the same node
# (e.g. a multi-replica Rancher install failing HA peer connections). Doing
# this up front avoids having to catch it later.
sudo sed -i 's/^FirewallBackend=.*/FirewallBackend=iptables/' /etc/firewalld/firewalld.conf
sudo systemctl restart firewalld
RHC_USERNAME=
RHC_PASSWORD=
sudo rhc connect --username "$RHC_USERNAME" --password "$RHC_PASSWORD"

  sudo subscription-manager status
  sudo subscription-manager refresh
  sudo subscription-manager release --list      # forces content-cert regen
  cat /etc/yum.repos.d/redhat.repo | head -30    # should now be hundreds of lines
  sudo subscription-manager repos --list 
  sudo dnf repolist

# There seems to be an issue with Red Hat's CDN (or mirrors?) when I tried this - so... try the first command, then the 2nd if the first does not work
sudo dnf update -y

# The following will keep trying (and eventually succeed)
while true; do sudo dnf update -y; sleep 5; done
# You will need to quit (CTRL-C) once evertyhing is updated)

# 1. Enable CodeReady Builder (EPEL expects it)
sudo subscription-manager repos --enable codeready-builder-for-rhel-10-x86_64-rpms

# 2. Install EPEL for RHEL 10
sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm

# 3. Install both tools
sudo dnf install -y fio sysbench

echo "SUCCESS - reboot and you're ready to go."
sudo shutdown now -r
