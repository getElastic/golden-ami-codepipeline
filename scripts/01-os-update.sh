#!/bin/bash
# 01-os-update.sh — Full OS update and baseline tooling
# Runs as root via: sudo bash '{{ .Path }}'
set -euxo pipefail

echo "================================================================"
echo " STEP 1: OS Update & Baseline Packages"
echo "================================================================"

# Full system update — security patches included
dnf update -y --security
dnf upgrade -y

# Baseline tools every golden AMI should have
dnf install -y \
  aws-cli \
  jq \
  wget \
  unzip \
  tar \
  gzip \
  htop \
  net-tools \
  bind-utils \
  telnet \
  nmap-ncat \
  tcpdump \
  strace \
  lsof \
  vim \
  git \
  openssl \
  ca-certificates \
  logrotate \
  cronie \
  at \
  acl \
  audit \
  aide \
  nftables \
  fail2ban \
  rng-tools

# Enable and start audit daemon — required for CIS compliance
systemctl enable auditd
systemctl start auditd

# Enable cronie (cron)
systemctl enable crond
systemctl start crond

# Enable rngd for entropy
systemctl enable rngd
systemctl start rngd

echo ">>> OS update and baseline packages complete"
