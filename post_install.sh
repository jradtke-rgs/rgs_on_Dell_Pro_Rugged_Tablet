#!/bin/bash

# The following are tasks intended for the Base OS
# Specific testing is located in [Procedure.md](./Procedure.md)

DAUSER=mansible
echo "$DAUSER ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/$DAUSER-nopasswd-all

sudo systemctl enable sshd

sudo rhc connect --username '(USERNAME)' --password '(PASSWORD)'

  sudo subscription-manager status
  sudo subscription-manager refresh
  sudo subscription-manager release --list      # forces content-cert regen
  cat /etc/yum.repos.d/redhat.repo | head -30    # should now be hundreds of lines
  sudo subscription-manager repos --list | head
  sudo dnf repolist

# sudo dnf update -y
# There seems to be an issue with Red Hat's CDN (or mirrors?)
# The following will keep trying (and eventually succeed)
while true; do sudo dnf update -y; sleep 5; done
# You will need to quit (CTRL-C) once evertyhing is updated)
shutdown now -r

  # 1. Enable CodeReady Builder (EPEL expects it)
  sudo subscription-manager repos --enable codeready-builder-for-rhel-10-x86_64-rpms

  # 2. Install EPEL for RHEL 10
  sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm

  # 3. Install both tools
  sudo dnf install -y fio sysbench

