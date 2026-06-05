#!/bin/bash
# 02-cis-hardening.sh — CIS Amazon Linux 2023 Benchmark Level 1
# Key sections: filesystem, SSH, user accounts, network, logging
# Reference: CIS Amazon Linux 2023 Benchmark v1.0
set -euxo pipefail

echo "================================================================"
echo " STEP 2: CIS Level 1 Hardening"
echo "================================================================"

# -----------------------------------------------------------------------
# 1. Filesystem hardening
# -----------------------------------------------------------------------

echo ">>> Filesystem: disable unused filesystems"
cat > /etc/modprobe.d/cis-filesystem.conf << 'EOF'
install cramfs /bin/false
install freevxfs /bin/false
install jffs2 /bin/false
install hfs /bin/false
install hfsplus /bin/false
install squashfs /bin/false
install udf /bin/false
install fat /bin/false
install vfat /bin/false
install usb-storage /bin/false
EOF

echo ">>> Filesystem: /tmp mount options"
cat > /etc/systemd/system/tmp.mount << 'EOF'
[Unit]
Description=Temporary Directory /tmp
ConditionPathIsSymbolicLink=!/tmp
DefaultDependencies=no
Conflicts=umount.target
Before=local-fs.target umount.target
After=swap.target

[Mount]
What=tmpfs
Where=/tmp
Type=tmpfs
Options=mode=1777,strictatime,noexec,nodev,nosuid,size=2G

[Install]
WantedBy=local-fs.target
EOF

systemctl daemon-reload
systemctl enable tmp.mount

echo ">>> Filesystem: /var/tmp noexec bind mount"
# /var/tmp should inherit noexec,nosuid,nodev from /tmp equivalent
grep -q '/var/tmp' /etc/fstab || \
  echo "tmpfs /var/tmp tmpfs defaults,noexec,nosuid,nodev,size=1G 0 0" >> /etc/fstab

# -----------------------------------------------------------------------
# 2. SSH Hardening (CIS 5.2)
# -----------------------------------------------------------------------

echo ">>> SSH: applying CIS hardening"
cat > /etc/ssh/sshd_config << 'EOF'
# CIS-hardened sshd_config — AL2023 Golden AMI

Protocol 2
Port 22

HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key

# Authentication
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
UsePAM yes
ChallengeResponseAuthentication no
KerberosAuthentication no
GSSAPIAuthentication no

# Session hardening
MaxAuthTries 4
MaxSessions 10
LoginGraceTime 60
ClientAliveInterval 300
ClientAliveCountMax 3
TCPKeepAlive no

# Forwarding — disable unless needed
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PermitTunnel no

# Environment
PermitUserEnvironment no
AcceptEnv LANG LC_*

# Logging
SyslogFacility AUTHPRIV
LogLevel VERBOSE

# SFTP
Subsystem sftp /usr/libexec/openssh/sftp-server

# Ciphers and MACs (CIS 5.2.13-15)
Ciphers aes128-ctr,aes192-ctr,aes256-ctr,aes128-gcm@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-256,hmac-sha2-512,hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group14-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,ecdh-sha2-nistp256,ecdh-sha2-nistp521

# Banner
Banner /etc/issue.net
EOF

# Warning banner
cat > /etc/issue.net << 'EOF'
*******************************************************************************
  AUTHORISED ACCESS ONLY
  This system is for authorised users only. All activity may be monitored
  and reported. Unauthorised access is a criminal offence.
*******************************************************************************
EOF

chmod 644 /etc/issue.net
systemctl restart sshd

# -----------------------------------------------------------------------
# 3. User and password policy (CIS 5.4, 5.5)
# -----------------------------------------------------------------------

echo ">>> Users: password and account policies"

# Password aging
sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   90/'  /etc/login.defs
sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS   7/'   /etc/login.defs
sed -i 's/^PASS_WARN_AGE.*/PASS_WARN_AGE   14/'  /etc/login.defs

# Minimum password length
sed -i 's/^PASS_MIN_LEN.*/PASS_MIN_LEN    14/'   /etc/login.defs

# Password quality via PAM
cat > /etc/security/pwquality.conf << 'EOF'
minlen = 14
minclass = 4
maxrepeat = 3
maxsequence = 3
dcredit = -1
ucredit = -1
ocredit = -1
lcredit = -1
EOF

# Account lockout — 5 failures, 15 min lockout
cat > /etc/security/faillock.conf << 'EOF'
deny = 5
unlock_time = 900
fail_interval = 900
even_deny_root
EOF

# Umask hardening
sed -i 's/^UMASK.*/UMASK           027/' /etc/login.defs
echo "umask 027" >> /etc/profile.d/cis-umask.sh

# Lock system accounts that should not have interactive shells
echo ">>> Users: locking system accounts"
awk -F: '($3 < 1000) {print $1}' /etc/passwd | \
  grep -v -E '^(root|sync|shutdown|halt)$' | \
  while read -r user; do
    usermod -L "$user" 2>/dev/null || true
    usermod -s /sbin/nologin "$user" 2>/dev/null || true
  done

# -----------------------------------------------------------------------
# 4. Network hardening (CIS 3)
# -----------------------------------------------------------------------

echo ">>> Network: kernel parameter hardening"
cat > /etc/sysctl.d/99-cis-network.conf << 'EOF'
# CIS Network hardening

# Disable IP forwarding (enable only if this is a NAT/router instance)
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0

# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Disable ICMP redirect acceptance
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Disable secure ICMP redirect acceptance
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0

# Enable reverse path filtering
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Log suspicious packets
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Disable broadcast ICMP
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Ignore bogus ICMP error responses
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Enable TCP SYN cookies
net.ipv4.tcp_syncookies = 1

# Disable IPv6 if not needed (adjust for your environment)
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1

# Kernel hardening
kernel.randomize_va_space = 2
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.sysrq = 0
fs.suid_dumpable = 0
EOF

sysctl --system

# Disable IPv6 in grub as well
if grep -q "GRUB_CMDLINE_LINUX" /etc/default/grub; then
  sed -i 's/GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 ipv6.disable=1"/' /etc/default/grub
  grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true
fi

# -----------------------------------------------------------------------
# 5. Audit logging (CIS 4)
# -----------------------------------------------------------------------

echo ">>> Audit: configuring auditd rules"
cat > /etc/audit/rules.d/99-cis.rules << 'EOF'
# Delete all existing rules
-D

# Buffer size
-b 8192

# Failure mode: 1=print, 2=panic
-f 1

# ---- Identity and access changes ----
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group  -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers

# ---- Authentication events ----
-w /var/log/faillog -p wa -k logins
-w /var/log/lastlog -p wa -k logins
-w /var/run/faillock/ -p wa -k logins

# ---- Privileged commands ----
-a always,exit -F path=/usr/bin/sudo    -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/bin/su      -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/bin/newgrp  -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/bin/chage   -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/bin/passwd  -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/sbin/usermod -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/sbin/useradd -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/sbin/userdel -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged

# ---- System calls ----
-a always,exit -F arch=b64 -S adjtimex,settimeofday -k time-change
-a always,exit -F arch=b64 -S clock_settime -k time-change
-w /etc/localtime -p wa -k time-change

-a always,exit -F arch=b64 -S sethostname,setdomainname -k system-locale
-w /etc/hosts       -p wa -k system-locale
-w /etc/hostname    -p wa -k system-locale

-a always,exit -F arch=b64 -S mount -F auid>=1000 -F auid!=4294967295 -k mounts
-a always,exit -F arch=b64 -S unlink,unlinkat,rename,renameat -F auid>=1000 -F auid!=4294967295 -k delete

# ---- Kernel modules ----
-w /sbin/insmod  -p x -k modules
-w /sbin/rmmod   -p x -k modules
-w /sbin/modprobe -p x -k modules
-a always,exit -F arch=b64 -S init_module,delete_module -k modules

# ---- Make rules immutable (must reboot to change) ----
# Uncomment in production after validating rules
# -e 2
EOF

augenrules --load
service auditd restart || true

# -----------------------------------------------------------------------
# 6. AIDE — filesystem integrity monitoring
# -----------------------------------------------------------------------

echo ">>> AIDE: initializing integrity database"
aide --init
mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz

# Daily AIDE check via cron
echo "0 5 * * * root /usr/sbin/aide --check 2>&1 | /usr/bin/logger -t aide" \
  > /etc/cron.d/aide-check

# -----------------------------------------------------------------------
# 7. Disable unused services
# -----------------------------------------------------------------------

echo ">>> Services: disabling unnecessary services"
SERVICES_TO_DISABLE=(
  "avahi-daemon"
  "cups"
  "dhcpd"
  "slapd"
  "nfs"
  "rpcbind"
  "named"
  "vsftpd"
  "httpd"
  "dovecot"
  "smb"
  "squid"
  "snmpd"
  "ypserv"
  "tftp"
  "telnet.socket"
  "rsh.socket"
  "rlogin.socket"
  "rexec.socket"
)

for svc in "${SERVICES_TO_DISABLE[@]}"; do
  systemctl stop    "$svc" 2>/dev/null || true
  systemctl disable "$svc" 2>/dev/null || true
done

echo ">>> CIS Level 1 hardening complete"
