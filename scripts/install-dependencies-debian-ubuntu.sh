#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  SUDO="sudo"
else
  SUDO=""
fi

ARCH="$(dpkg --print-architecture)"
case "${ARCH}" in
  amd64) AWSCLI_ARCH="x86_64" ;;
  arm64) AWSCLI_ARCH="aarch64" ;;
  *)
    echo "Unsupported architecture: ${ARCH}. Supported: amd64, arm64."
    exit 1
    ;;
esac

source /etc/os-release
CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"

if [[ -z "${CODENAME}" ]]; then
  if command -v lsb_release >/dev/null 2>&1; then
    CODENAME="$(lsb_release -cs)"
  else
    echo "Could not determine distro codename. Install lsb-release or set UBUNTU_CODENAME."
    exit 1
  fi
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "Installing base packages..."
${SUDO} apt-get update
${SUDO} apt-get install -y \
  apt-transport-https \
  ca-certificates \
  curl \
  git \
  gnupg \
  jq \
  lsb-release \
  make \
  unzip \
  wget

echo "Installing HashiCorp APT repository..."
curl -fsSL https://apt.releases.hashicorp.com/gpg | ${SUDO} gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=${ARCH} signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${CODENAME} main" | \
  ${SUDO} tee /etc/apt/sources.list.d/hashicorp.list >/dev/null

echo "Installing Terraform and Packer..."
${SUDO} apt-get update
${SUDO} apt-get install -y terraform packer

echo "Installing AWS CLI v2..."
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWSCLI_ARCH}.zip" -o "${TMP_DIR}/awscliv2.zip"
unzip -q "${TMP_DIR}/awscliv2.zip" -d "${TMP_DIR}"
${SUDO} "${TMP_DIR}/aws/install" --update

echo "Installing Session Manager plugin..."
case "${ARCH}" in
  amd64)
    curl -fsSL "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o "${TMP_DIR}/session-manager-plugin.deb"
    ;;
  arm64)
    curl -fsSL "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_arm64/session-manager-plugin.deb" -o "${TMP_DIR}/session-manager-plugin.deb"
    ;;
esac
${SUDO} dpkg -i "${TMP_DIR}/session-manager-plugin.deb"

echo
echo "Installed versions:"
terraform version | head -n 1
packer version
aws --version
session-manager-plugin --version
