#!/usr/bin/env bash
# =============================================================================
#  Fedora 44 Setup Script
#  Run with: bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/setup.sh)
# =============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${GREEN}[✔]${RESET} $*"; }
info() { echo -e "${BLUE}[➜]${RESET} $*"; }
warn() { echo -e "${YELLOW}[!]${RESET} $*"; }
die()  { echo -e "${RED}[✘]${RESET} $*" >&2; exit 1; }

# ── Preflight ─────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] && die "Run this script as your regular user (not root). sudo will be used internally."
command -v dnf &>/dev/null || die "This script requires dnf (Fedora)."

CURRENT_USER="$(whoami)"
info "Setting up Fedora 44 for user: ${BOLD}${CURRENT_USER}${RESET}"
echo

# =============================================================================
#  1. FISH SHELL
# =============================================================================
info "Installing Fish shell..."
sudo dnf install -y fish

FISH_PATH="$(command -v fish)"
if ! grep -qF "$FISH_PATH" /etc/shells; then
  echo "$FISH_PATH" | sudo tee -a /etc/shells > /dev/null
fi
sudo chsh -s "$FISH_PATH" "$CURRENT_USER"
log "Fish installed and set as default shell (${FISH_PATH})"

# =============================================================================
#  2. MICROSOFT EDGE
# =============================================================================
info "Installing Microsoft Edge..."
sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc

cat <<'EOF' | sudo tee /etc/yum.repos.d/microsoft-edge.repo > /dev/null
[microsoft-edge]
name=microsoft-edge
baseurl=https://packages.microsoft.com/yumrepos/edge
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF

sudo dnf install -y microsoft-edge-stable
log "Microsoft Edge installed"

# =============================================================================
#  3. 1PASSWORD
# =============================================================================
info "Installing 1Password..."
sudo rpm --import https://downloads.1password.com/linux/keys/1password.asc

cat <<'EOF' | sudo tee /etc/yum.repos.d/1password.repo > /dev/null
[1password]
name=1Password Stable Channel
baseurl=https://downloads.1password.com/linux/rpm/stable/$basearch
enabled=1
gpgcheck=1
gpgkey=https://downloads.1password.com/linux/keys/1password.asc
EOF

sudo dnf install -y 1password 1password-cli
log "1Password + CLI installed"

# ── 1Password SSH Agent ───────────────────────────────────────────────────────
info "Configuring 1Password SSH agent..."

# systemd user socket path used by 1Password
OP_SSH_SOCKET="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/1password/agent.sock"

# SSH config: prefer 1Password agent, fall back to system agent
mkdir -p "${HOME}/.ssh"
SSH_CONFIG="${HOME}/.ssh/config"

if ! grep -qF "1password" "$SSH_CONFIG" 2>/dev/null; then
  cat >> "$SSH_CONFIG" <<EOF

# ── 1Password SSH Agent ────────────────────────────────
Host *
  IdentityAgent ${OP_SSH_SOCKET}
EOF
  chmod 600 "$SSH_CONFIG"
fi

# Fish: export SSH_AUTH_SOCK for sessions that need it explicitly
FISH_CONF_DIR="${HOME}/.config/fish/conf.d"
mkdir -p "$FISH_CONF_DIR"
cat > "${FISH_CONF_DIR}/1password-ssh.fish" <<EOF
# 1Password SSH agent socket
set -gx SSH_AUTH_SOCK "${OP_SSH_SOCKET}"
EOF

warn "1Password SSH agent configured. Make sure to:"
warn "  1. Open 1Password → Settings → Developer → enable SSH Agent"
warn "  2. Enable 'Use the SSH agent' for each key you want available"
log "1Password SSH agent config written"

# =============================================================================
#  4. ASDF (latest) + Node.js plugin
# =============================================================================
info "Installing ASDF version manager (latest)..."

ASDF_DIR="${HOME}/.asdf"

# Fetch the latest release tag from GitHub
ASDF_VERSION="$(curl -fsSL https://api.github.com/repos/asdf-vm/asdf/releases/latest \
  | grep '"tag_name"' | sed 's/.*"tag_name": *"\(.*\)".*/\1/')"

if [[ -d "$ASDF_DIR" ]]; then
  warn "ASDF already exists at ${ASDF_DIR}, pulling latest..."
  git -C "$ASDF_DIR" fetch --tags --prune
  git -C "$ASDF_DIR" checkout "$ASDF_VERSION"
else
  git clone --depth 1 --branch "$ASDF_VERSION" \
    https://github.com/asdf-vm/asdf.git "$ASDF_DIR"
fi
log "ASDF ${ASDF_VERSION} installed"

# Fish integration
cat > "${FISH_CONF_DIR}/asdf.fish" <<'EOF'
# ASDF version manager
source ~/.asdf/asdf.fish
EOF

# Install completions for Fish
mkdir -p "${HOME}/.config/fish/completions"
ln -sf "${ASDF_DIR}/completions/asdf.fish" \
       "${HOME}/.config/fish/completions/asdf.fish" 2>/dev/null || true

# Source asdf for the rest of this script (bash context)
# shellcheck source=/dev/null
. "${ASDF_DIR}/asdf.sh"

info "Installing ASDF Node.js plugin..."
sudo dnf install -y gpg dirmngr  # needed for nodejs key verification
asdf plugin add nodejs https://github.com/asdf-vm/asdf-nodejs.git 2>/dev/null || \
  warn "nodejs plugin already added, skipping"

info "Installing latest LTS Node.js via ASDF..."
asdf install nodejs lts
asdf set -u nodejs lts

NODE_VERSION="$(asdf current nodejs | awk '{print $2}')"
log "Node.js ${NODE_VERSION} (LTS) set as global default"

# =============================================================================
#  5. DOCKER
# =============================================================================
info "Installing Docker..."

# Remove any old conflicting packages
sudo dnf remove -y docker docker-client docker-client-latest docker-common \
  docker-latest docker-latest-logrotate docker-logrotate docker-selinux \
  docker-engine-selinux docker-engine 2>/dev/null || true

# Add Docker's official repo
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager addrepo \
  --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo

sudo dnf install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

# Enable & start Docker
sudo systemctl enable --now docker

# Add current user to docker group (no sudo needed for docker commands)
sudo usermod -aG docker "$CURRENT_USER"
log "Docker installed and enabled (you'll need to log out/in for group to apply)"

# =============================================================================
#  DONE
# =============================================================================
echo
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║         Setup complete! 🎉                   ║${RESET}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${RESET}"
echo
echo -e "  ${BOLD}Next steps:${RESET}"
echo -e "  1. ${YELLOW}Log out and back in${RESET} — required for:"
echo -e "     • Fish to be your default shell"
echo -e "     • Docker group membership"
echo -e "  2. Open ${BOLD}1Password${RESET} → Settings → Developer → enable SSH Agent"
echo -e "  3. Verify Node.js:  ${BLUE}node --version${RESET}"
echo -e "  4. Verify Docker:   ${BLUE}docker run hello-world${RESET}"
echo -e "  5. Verify ASDF:     ${BLUE}asdf --version${RESET}"
echo
