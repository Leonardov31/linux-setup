#!/usr/bin/env bash
# =============================================================================
#  Fedora 44 Setup Script
#  Run with: bash <(curl -fsSL https://raw.githubusercontent.com/Leonardov31/linux-setup/main/setup.sh)
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
ARCH="$(uname -m)"

# ── Banner / consent ──────────────────────────────────────────────────────────
cat <<EOF

${BOLD}Fedora 44 Setup Script${RESET}
This will install:
  • Fish shell (and set it as default)
  • Microsoft Edge, 1Password (+ CLI + SSH agent config)
  • asdf (Go binary, v0.16+) with Node.js LTS and Flutter
  • Docker (and add ${CURRENT_USER} to the docker group)
  • Android SDK (cmdline-tools, platform-tools, android-35)
  • Zed editor, Claude Code, GitHub Copilot CLI

It will use ${BOLD}sudo${RESET} for system package installs and shell change.
Setting up for user: ${BOLD}${CURRENT_USER}${RESET}  (arch: ${ARCH})

EOF
read -r -p "Press Enter to continue, or Ctrl-C to abort... " _

# ── Base prerequisites ────────────────────────────────────────────────────────
info "Installing base prerequisites (git, curl, tar, jq)..."
sudo dnf install -y git curl tar jq unzip wget
log "Base prerequisites installed"

# Fish conf.d dir is referenced by many sections — create once up front
FISH_CONF_DIR="${HOME}/.config/fish/conf.d"
mkdir -p "$FISH_CONF_DIR"

# =============================================================================
#  1. FISH SHELL
# =============================================================================
info "Installing Fish shell..."
sudo dnf install -y fish

FISH_PATH="$(command -v fish)"
if ! grep -qF "$FISH_PATH" /etc/shells; then
  echo "$FISH_PATH" | sudo tee -a /etc/shells > /dev/null
fi

# Defer the actual `chsh` to the end of the script, so a partial failure
# doesn't leave the user with Fish + a broken Fish config on next login.
log "Fish installed (${FISH_PATH}) — default shell will be set at the end"

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

# SSH config: prefer 1Password agent for github.com (and similar dev hosts)
# only — NOT `Host *`, which would break system keys, CI runners, etc.
mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"
SSH_CONFIG="${HOME}/.ssh/config"
SSH_MARK_BEGIN="# >>> 1password-ssh-agent (managed by setup.sh) >>>"
SSH_MARK_END="# <<< 1password-ssh-agent <<<"

if ! grep -qF "$SSH_MARK_BEGIN" "$SSH_CONFIG" 2>/dev/null; then
  cat >> "$SSH_CONFIG" <<EOF

${SSH_MARK_BEGIN}
# Use 1Password's SSH agent for common Git/dev hosts.
# To override on a specific host, declare it BEFORE this block in this file
# (ssh applies the FIRST matching IdentityAgent it sees).
Host github.com gitlab.com bitbucket.org *.github.com
  IdentityAgent ${OP_SSH_SOCKET}
${SSH_MARK_END}
EOF
  chmod 600 "$SSH_CONFIG"
fi

# NOTE: We intentionally do NOT export SSH_AUTH_SOCK globally in Fish.
# A global export breaks every SSH attempt before 1Password is running.
# The `IdentityAgent` directive above handles per-host routing safely.

warn "1Password SSH agent configured. Make sure to:"
warn "  1. Open 1Password → Settings → Developer → enable SSH Agent"
warn "  2. Enable 'Use the SSH agent' for each key you want available"
log "1Password SSH agent config written"

# =============================================================================
#  4. ASDF (Go binary, v0.16+) + Node.js plugin
# =============================================================================
info "Installing asdf version manager (Go binary)..."

# Map uname -m → asdf release arch
case "$ARCH" in
  x86_64)  ASDF_ARCH="amd64" ;;
  aarch64) ASDF_ARCH="arm64" ;;
  *)       die "Unsupported architecture for asdf: $ARCH" ;;
esac

# Get the latest release tag (e.g. "v0.18.0")
ASDF_TAG="$(curl -fsSL https://api.github.com/repos/asdf-vm/asdf/releases/latest \
              | jq -r '.tag_name')"
[[ -n "$ASDF_TAG" && "$ASDF_TAG" != "null" ]] || die "Could not determine latest asdf release"
ASDF_VERSION="${ASDF_TAG#v}"

# Install the asdf binary into ~/.local/bin
mkdir -p "${HOME}/.local/bin"
ASDF_TARBALL="asdf-${ASDF_TAG}-linux-${ASDF_ARCH}.tar.gz"
ASDF_URL="https://github.com/asdf-vm/asdf/releases/download/${ASDF_TAG}/${ASDF_TARBALL}"

info "Downloading ${ASDF_TARBALL}..."
curl -fsSL "$ASDF_URL" | tar -xz -C "${HOME}/.local/bin" asdf
chmod +x "${HOME}/.local/bin/asdf"

# asdf data dir (where plugins, installs, and shims live)
export ASDF_DATA_DIR="${HOME}/.asdf"
mkdir -p "${ASDF_DATA_DIR}"

# Make asdf usable for the rest of THIS bash script
export PATH="${ASDF_DATA_DIR}/shims:${HOME}/.local/bin:${PATH}"

# Verify
asdf --version
log "asdf ${ASDF_VERSION} installed at ${HOME}/.local/bin/asdf"

# Fish integration: PATH + completions
cat > "${FISH_CONF_DIR}/asdf.fish" <<'EOF'
# asdf version manager (Go binary, v0.16+)
set -gx ASDF_DATA_DIR "$HOME/.asdf"
fish_add_path "$ASDF_DATA_DIR/shims" "$HOME/.local/bin"
EOF

# Generate Fish completions
mkdir -p "${HOME}/.config/fish/completions"
asdf completion fish > "${HOME}/.config/fish/completions/asdf.fish" 2>/dev/null || \
  warn "Could not generate asdf Fish completions (non-fatal)"

# ── Node.js via asdf ──────────────────────────────────────────────────────────
info "Installing asdf Node.js plugin..."
asdf plugin add nodejs https://github.com/asdf-vm/asdf-nodejs.git 2>/dev/null || \
  warn "nodejs plugin already added, skipping"

info "Installing latest LTS Node.js via asdf..."
asdf install nodejs lts
asdf set -u nodejs lts
asdf reshim nodejs

NODE_VERSION="$(asdf current nodejs 2>/dev/null | awk 'NR==1 {print $2}')"
log "Node.js ${NODE_VERSION:-(LTS)} set as default in \$HOME"

# =============================================================================
#  5. DOCKER
# =============================================================================
info "Installing Docker..."

# Remove any old conflicting packages
sudo dnf remove -y docker docker-client docker-client-latest docker-common \
  docker-latest docker-latest-logrotate docker-logrotate docker-selinux \
  docker-engine-selinux docker-engine 2>/dev/null || true

sudo dnf install -y dnf-plugins-core

# `dnf config-manager addrepo --from-repofile=URL` has a bug in dnf5
# (rpm-software-management/dnf5#1603): it chokes on empty lines in
# docker-ce.repo with "Cannot set repository option '#1= '". Sidestep it
# entirely by writing the .repo file directly, the same way we did for
# Microsoft Edge and 1Password above.
DOCKER_REPO_URL="https://download.docker.com/linux/fedora/docker-ce.repo"
info "Adding Docker CE repo..."
curl -fsSL "$DOCKER_REPO_URL" | sudo tee /etc/yum.repos.d/docker-ce.repo > /dev/null

sudo dnf install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

sudo systemctl enable --now docker
sudo usermod -aG docker "$CURRENT_USER"
log "Docker installed and enabled (log out/in for group membership to apply)"

# =============================================================================
#  6. ANDROID SDK (Command-line tools)
# =============================================================================
info "Installing Android SDK dependencies (JDK 21)..."

# Fedora 42+ retired the legacy java-(1.8.0, 11, 17)-openjdk packages.
# Fedora 44 ships JDK 21 as the system OpenJDK; AGP officially targets
# JDK 17 but runs on JDK 21 with recent Gradle (8.5+). If a project's
# Gradle wrapper is too old, set its `distributionUrl` to gradle 8.5+.
sudo dnf install -y java-21-openjdk java-21-openjdk-devel

# Locate the JDK 21 install root (typically /usr/lib/jvm/java-21-openjdk-...)
JAVA_HOME_PATH="$(rpm -ql java-21-openjdk-devel | grep -m1 '/bin/javac$' | sed 's|/bin/javac$||')"
[[ -d "$JAVA_HOME_PATH" ]] || die "Could not locate JDK 21 install root"
export JAVA_HOME="$JAVA_HOME_PATH"
export PATH="${JAVA_HOME}/bin:${PATH}"
log "JAVA_HOME pinned to ${JAVA_HOME}"

ANDROID_HOME="${HOME}/Android/Sdk"
CMDLINE_TOOLS_DIR="${ANDROID_HOME}/cmdline-tools"
mkdir -p "$CMDLINE_TOOLS_DIR"

# NOTE: Google's "_latest.zip" filename is misleading — this URL pins a
# specific build (11076708). Bump periodically by checking
# https://developer.android.com/studio#command-line-tools-only
info "Downloading Android command-line tools (pinned build 11076708)..."
CMDTOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
CMDTOOLS_ZIP="/tmp/cmdline-tools.zip"
curl -fsSL "$CMDTOOLS_URL" -o "$CMDTOOLS_ZIP"
unzip -q -o "$CMDTOOLS_ZIP" -d "$CMDLINE_TOOLS_DIR"
rm -f "$CMDTOOLS_ZIP"

# Google ships the tools as "cmdline-tools/"; sdkmanager expects "latest/" layout.
# Fail loudly if the source dir isn't where we expect.
if [[ -d "${CMDLINE_TOOLS_DIR}/cmdline-tools" ]]; then
  rm -rf "${CMDLINE_TOOLS_DIR}/latest"
  mv "${CMDLINE_TOOLS_DIR}/cmdline-tools" "${CMDLINE_TOOLS_DIR}/latest"
elif [[ ! -d "${CMDLINE_TOOLS_DIR}/latest" ]]; then
  die "Unexpected Android cmdline-tools zip layout under ${CMDLINE_TOOLS_DIR}"
fi

export ANDROID_HOME
export PATH="${CMDLINE_TOOLS_DIR}/latest/bin:${ANDROID_HOME}/platform-tools:${PATH}"

info "Accepting Android SDK licenses..."
yes | sdkmanager --licenses > /dev/null || \
  warn "sdkmanager --licenses returned non-zero (may be benign)"

info "Installing Android SDK components..."
sdkmanager --install \
  "platform-tools" \
  "platforms;android-35" \
  "build-tools;35.0.0" \
  "emulator" \
  "system-images;android-35;google_apis;x86_64"

log "Android SDK installed at ${ANDROID_HOME}"

# Fish: persist Android environment using fish_add_path (cleaner than $PATH heredoc)
cat > "${FISH_CONF_DIR}/android.fish" <<EOF
# Android SDK
set -gx ANDROID_HOME "${ANDROID_HOME}"
set -gx JAVA_HOME "${JAVA_HOME_PATH}"
fish_add_path "${CMDLINE_TOOLS_DIR}/latest/bin"
fish_add_path "${ANDROID_HOME}/platform-tools"
fish_add_path "${ANDROID_HOME}/emulator"
fish_add_path "${JAVA_HOME_PATH}/bin"
EOF

# =============================================================================
#  7. FLUTTER (via asdf)
# =============================================================================
info "Installing Flutter via asdf..."

# Flutter Linux desktop dependencies
sudo dnf install -y \
  clang cmake ninja-build gtk3-devel \
  mesa-libGL-devel mesa-libGLU-devel \
  libX11-devel libXcomposite-devel libXcursor-devel \
  libXdamage-devel libXext-devel libXfixes-devel \
  libXi-devel libXrandr-devel libXrender-devel \
  libXtst-devel at-spi2-core-devel

asdf plugin add flutter https://github.com/asdf-community/asdf-flutter.git 2>/dev/null || \
  warn "flutter plugin already added, skipping"

# Pin to the latest STABLE channel (asdf-flutter uses suffixes like -stable / -beta)
info "Resolving latest stable Flutter version..."
FLUTTER_VERSION="$(asdf list all flutter 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+-stable$' | tail -1)"
[[ -n "$FLUTTER_VERSION" ]] || die "Could not resolve latest stable Flutter version"
info "Installing Flutter ${FLUTTER_VERSION}..."
asdf install flutter "$FLUTTER_VERSION"
asdf set -u flutter "$FLUTTER_VERSION"
asdf reshim flutter

# Make sure the Flutter shim is on PATH for the rest of this script
export PATH="${ASDF_DATA_DIR}/shims:${PATH}"

# Point Flutter at the Android SDK
flutter config --android-sdk "$ANDROID_HOME" --no-analytics

# Accept Flutter's copy of Android licenses (don't mask stderr — surface real errors)
yes | flutter doctor --android-licenses > /dev/null || \
  warn "flutter doctor --android-licenses returned non-zero (may be benign)"

log "Flutter ${FLUTTER_VERSION} installed and configured"

info "Running flutter doctor (informational; non-fatal)..."
flutter doctor || true

# =============================================================================
#  8. ZED EDITOR
# =============================================================================
info "Installing Zed editor..."
curl -fsSL https://zed.dev/install.sh | sh

cat > "${FISH_CONF_DIR}/zed.fish" <<'EOF'
# Zed editor
fish_add_path "$HOME/.local/bin"
EOF
log "Zed editor installed"

# =============================================================================
#  9. CLAUDE CODE (native installer — no Node.js required)
# =============================================================================
info "Installing Claude Code (native installer)..."
curl -fsSL https://claude.ai/install.sh | bash

# Binary lands at ~/.claude/bin/claude or ~/.local/bin/claude
cat > "${FISH_CONF_DIR}/claude-code.fish" <<'EOF'
# Claude Code
fish_add_path "$HOME/.claude/bin"
fish_add_path "$HOME/.local/bin"
EOF
log "Claude Code installed (auto-updates in the background)"

# =============================================================================
#  10. GITHUB COPILOT CLI (no Node.js required)
# =============================================================================
info "Installing GitHub Copilot CLI..."
curl -fsSL https://gh.io/copilot-install | bash

cat > "${FISH_CONF_DIR}/copilot.fish" <<'EOF'
# GitHub Copilot CLI
fish_add_path "$HOME/.local/bin"
EOF
export PATH="${HOME}/.local/bin:${PATH}"
log "GitHub Copilot CLI installed (requires a paid GitHub Copilot subscription)"

# =============================================================================
#  FINALIZE: Set Fish as default shell
# =============================================================================
# Done last so a mid-script failure doesn't leave the user logged into a
# Fish shell with a half-written ~/.config/fish/conf.d.
info "Setting Fish as default shell..."
sudo chsh -s "$FISH_PATH" "$CURRENT_USER"
log "Default shell set to ${FISH_PATH}"

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
echo -e "     • Android/Flutter/asdf PATH vars"
echo -e "  2. Open ${BOLD}1Password${RESET} → Settings → Developer → enable SSH Agent"
echo -e "     (only github.com / gitlab.com / bitbucket.org are routed by default —"
echo -e "      edit ~/.ssh/config to add more hosts)"
echo -e "  3. Authenticate ${BOLD}Claude Code${RESET}:   ${BLUE}claude${RESET}  (requires Pro / Max / Console)"
echo -e "  4. Authenticate ${BOLD}Copilot CLI${RESET}:   ${BLUE}copilot${RESET} then ${BLUE}/login${RESET}  (requires Copilot subscription)"
echo -e "  5. Verify Node.js:  ${BLUE}node --version${RESET}"
echo -e "  6. Verify Docker:   ${BLUE}docker run hello-world${RESET}"
echo -e "  7. Verify Flutter:  ${BLUE}flutter doctor${RESET}"
echo -e "  8. Verify Android:  ${BLUE}sdkmanager --list_installed${RESET}"
echo -e "  9. Verify Zed:      ${BLUE}zed --version${RESET}"
echo -e " 10. ${YELLOW}Android Studio${RESET} (optional GUI IDE):"
echo -e "     ${BLUE}flatpak install flathub com.google.AndroidStudio${RESET}"
echo
