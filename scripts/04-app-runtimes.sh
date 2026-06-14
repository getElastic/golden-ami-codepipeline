#!/bin/bash
# 04-app-runtimes.sh — Install Java, Node.js, and Python runtimes
# Versions passed as environment variables from Packer
set -euxo pipefail

echo "================================================================"
echo " STEP 4: App Runtimes"
echo "================================================================"

JAVA_VERSION="${JAVA_VERSION:-17}"
NODE_VERSION="${NODE_VERSION:-20}"
PYTHON_VERSION="${PYTHON_VERSION:-3.11}"

# -----------------------------------------------------------------------
# Java — Amazon Corretto (AWS-supported OpenJDK)
# -----------------------------------------------------------------------

echo ">>> Java: installing Amazon Corretto ${JAVA_VERSION}"

# AL2023 ships Corretto in its repos
dnf install -y "java-${JAVA_VERSION}-amazon-corretto-devel"

# Verify
java -version 2>&1
javac -version 2>&1

JAVA_HOME_PATH=$(dirname $(dirname $(readlink -f $(which java))))
echo "JAVA_HOME=${JAVA_HOME_PATH}" >> /etc/environment
echo "export JAVA_HOME=${JAVA_HOME_PATH}" > /etc/profile.d/java.sh
echo "export PATH=\$JAVA_HOME/bin:\$PATH" >> /etc/profile.d/java.sh
chmod 644 /etc/profile.d/java.sh

echo ">>> Java ${JAVA_VERSION}: installed at ${JAVA_HOME_PATH}"

# -----------------------------------------------------------------------
# Node.js — via NodeSource (pins to LTS)
# -----------------------------------------------------------------------

echo ">>> Node.js: installing v${NODE_VERSION} via NodeSource"

# Add the NodeSource repo directly (GPG-verified) instead of piping their
# setup script to bash — avoids executing an unverified remote script.
rpm --import https://rpm.nodesource.com/gpgkey/ns-operations-public.key

cat > /etc/yum.repos.d/nodesource-nodejs.repo <<EOF
[nodesource-nodejs]
name=Node.js Packages for Amazon Linux - \$basearch
baseurl=https://rpm.nodesource.com/pub_${NODE_VERSION}.x/nodistro/nodejs/\$basearch
enabled=1
gpgcheck=1
gpgkey=https://rpm.nodesource.com/gpgkey/ns-operations-public.key
module_hotfixes=1
EOF

dnf install -y nodejs

# Verify
node --version
npm --version

# Set npm global prefix to avoid permission issues
mkdir -p /usr/local/lib/npm-global
npm config set prefix /usr/local/lib/npm-global
echo "export PATH=/usr/local/lib/npm-global/bin:\$PATH" > /etc/profile.d/node.sh
chmod 644 /etc/profile.d/node.sh

echo ">>> Node.js $(node --version): installed"

# -----------------------------------------------------------------------
# Python — AL2023 ships Python 3.11 by default; install extras
# -----------------------------------------------------------------------

echo ">>> Python: installing Python ${PYTHON_VERSION} and tooling"

# AL2023 includes python3 (3.11) by default; install pip and dev headers
dnf install -y \
  python3 \
  python3-pip \
  python3-devel \
  python3-setuptools \
  python3-wheel

# Upgrade pip
python3 -m pip install --upgrade pip setuptools wheel --ignore-installed

# Make python3 the default python
alternatives --install /usr/bin/python python /usr/bin/python3 1 2>/dev/null || true

python3 --version
pip3 --version

# Install useful Python tools globally
pip3 install \
  boto3 \
  awscli-local \
  virtualenv

echo ">>> Python $(python3 --version): installed"

# -----------------------------------------------------------------------
# Runtime manifest
# -----------------------------------------------------------------------

cat >> /etc/golden-ami/agent-versions.txt << EOF

Runtime Versions
----------------
Java:    $(java -version 2>&1 | head -1)
Node.js: $(node --version)
npm:     $(npm --version)
Python:  $(python3 --version)
pip:     $(pip3 --version)
EOF

echo ">>> App runtimes install complete"
