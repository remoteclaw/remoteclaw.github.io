#!/bin/sh
# shellcheck shell=bash
# Re-exec under bash if invoked via a non-bash shell (e.g. dash, zsh).
# The script uses bash features (arrays, [[ ]], set -o pipefail).
if [ -z "${BASH_VERSION:-}" ]; then
    # File invocation (sh install.sh) — re-exec with bash
    if [ -f "$0" ]; then
        exec bash "$0" "$@"
    fi
    # Pipe invocation (curl | sh) — $0 is not a file, give clear guidance
    echo "Error: bash is required. Run:" >&2
    echo "  curl -fsSL https://remoteclaw.org/install.sh | bash" >&2
    exit 1
fi

set -euo pipefail

# RemoteClaw Installer for macOS and Linux
# Usage: curl -fsSL https://remoteclaw.org/install.sh | sh
#        curl -fsSL https://remoteclaw.org/install.sh | sh -s -- --local

BOLD='\033[1m'
ACCENT='\033[38;2;99;102;241m'      # indigo #6366f1
INFO='\033[38;2;136;146;176m'       # text-secondary #8892b0
SUCCESS='\033[38;2;34;197;94m'      # green #22c55e
WARN='\033[38;2;234;179;8m'         # amber #eab308
ERROR='\033[38;2;239;68;68m'        # red #ef4444
MUTED='\033[38;2;90;100;128m'       # text-muted #5a6480
NC='\033[0m' # No Color

NODE_MIN_MAJOR=22
NODE_MIN_MINOR=12
NODE_MIN_VERSION="${NODE_MIN_MAJOR}.${NODE_MIN_MINOR}"

ORIGINAL_PATH="${PATH:-}"

TMPFILES=()
cleanup_tmpfiles() {
    local f
    for f in "${TMPFILES[@]:-}"; do
        rm -rf "$f" 2>/dev/null || true
    done
}
trap cleanup_tmpfiles EXIT

mktempfile() {
    local f
    f="$(mktemp)"
    TMPFILES+=("$f")
    echo "$f"
}

DOWNLOADER=""
detect_downloader() {
    if command -v curl &> /dev/null; then
        DOWNLOADER="curl"
        return 0
    fi
    if command -v wget &> /dev/null; then
        DOWNLOADER="wget"
        return 0
    fi
    ui_error "Missing downloader (curl or wget required)"
    exit 1
}

download_file() {
    local url="$1"
    local output="$2"
    if [[ -z "$DOWNLOADER" ]]; then
        detect_downloader
    fi
    if [[ "$DOWNLOADER" == "curl" ]]; then
        curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 1 --retry-connrefused -o "$output" "$url"
        return
    fi
    wget -q --https-only --secure-protocol=TLSv1_2 --tries=3 --timeout=20 -O "$output" "$url"
}

run_remote_bash() {
    local url="$1"
    local tmp
    tmp="$(mktempfile)"
    download_file "$url" "$tmp"
    /bin/bash "$tmp"
}

# --- UI helpers ---

ui_info() {
    echo -e "${MUTED}·${NC} $*"
}

ui_warn() {
    echo -e "${WARN}!${NC} $*"
}

ui_success() {
    echo -e "${SUCCESS}✓${NC} $*"
}

ui_error() {
    echo -e "${ERROR}✗${NC} $*"
}

ui_section() {
    echo ""
    echo -e "${ACCENT}${BOLD}$1${NC}"
}

INSTALL_STAGE_TOTAL=3
INSTALL_STAGE_CURRENT=0

ui_stage() {
    INSTALL_STAGE_CURRENT=$((INSTALL_STAGE_CURRENT + 1))
    ui_section "[${INSTALL_STAGE_CURRENT}/${INSTALL_STAGE_TOTAL}] $1"
}

print_installer_banner() {
    echo -e "${ACCENT}${BOLD}"
    echo "  RemoteClaw Installer"
    echo -e "${NC}${INFO}  Self-hosted middleware for AI coding agents.${NC}"
    echo ""
}

# --- OS detection ---

detect_os_or_die() {
    OS="unknown"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"
    elif [[ "$OSTYPE" == "linux-gnu"* ]] || [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
        OS="linux"
    fi

    if [[ "$OS" == "unknown" ]]; then
        ui_error "Unsupported operating system"
        echo "This installer supports macOS and Linux (including WSL)."
        echo "For Windows, use: iwr -useb https://remoteclaw.org/install.ps1 | iex"
        exit 1
    fi

    ui_success "Detected: $OS"
}

# --- Utility ---

is_root() {
    [[ "$(id -u)" -eq 0 ]]
}

require_sudo() {
    if [[ "$OS" != "linux" ]]; then
        return 0
    fi
    if is_root; then
        return 0
    fi
    if command -v sudo &> /dev/null; then
        if ! sudo -n true >/dev/null 2>&1; then
            ui_info "Administrator privileges required; enter your password"
            sudo -v
        fi
        return 0
    fi
    ui_error "sudo is required for system installs on Linux"
    echo "  Install sudo or re-run as root."
    exit 1
}

refresh_shell_command_cache() {
    hash -r 2>/dev/null || true
}

run_quiet_step() {
    local title="$1"
    shift

    if [[ "$VERBOSE" == "1" ]]; then
        "$@"
        return $?
    fi

    local log
    log="$(mktempfile)"

    if "$@" >"$log" 2>&1; then
        return 0
    fi

    ui_error "${title} failed"
    if [[ -s "$log" ]]; then
        tail -n 40 "$log" >&2 || true
    fi
    return 1
}

# --- Arch Linux detection ---

is_arch_linux() {
    if [[ -f /etc/os-release ]]; then
        local os_id
        os_id="$(grep -E '^ID=' /etc/os-release 2>/dev/null | cut -d'=' -f2 | tr -d '"' || true)"
        case "$os_id" in
            arch|manjaro|endeavouros|arcolinux|garuda|archarm|cachyos|archcraft)
                return 0
                ;;
        esac
        local os_id_like
        os_id_like="$(grep -E '^ID_LIKE=' /etc/os-release 2>/dev/null | cut -d'=' -f2 | tr -d '"' || true)"
        if [[ "$os_id_like" == *arch* ]]; then
            return 0
        fi
    fi
    if command -v pacman &> /dev/null; then
        return 0
    fi
    return 1
}

# --- Homebrew (macOS) ---

is_macos_admin_user() {
    if [[ "$OS" != "macos" ]]; then
        return 0
    fi
    if is_root; then
        return 0
    fi
    id -Gn "$(id -un)" 2>/dev/null | grep -qw "admin"
}

install_homebrew() {
    if [[ "$OS" == "macos" ]]; then
        if ! command -v brew &> /dev/null; then
            if ! is_macos_admin_user; then
                local current_user
                current_user="$(id -un 2>/dev/null || echo "${USER:-current user}")"
                ui_error "Homebrew installation requires a macOS Administrator account"
                echo "Current user (${current_user}) is not in the admin group."
                echo "Fix: ask an Administrator to run:"
                echo "  sudo dseditgroup -o edit -a ${current_user} -t user admin"
                echo "Then retry."
                exit 1
            fi
            ui_info "Homebrew not found, installing"
            run_quiet_step "Installing Homebrew" run_remote_bash "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"

            if [[ -f "/opt/homebrew/bin/brew" ]]; then
                eval "$(/opt/homebrew/bin/brew shellenv)"
            elif [[ -f "/usr/local/bin/brew" ]]; then
                eval "$(/usr/local/bin/brew shellenv)"
            fi
            ui_success "Homebrew installed"
        else
            ui_success "Homebrew already installed"
        fi
    fi
}

# --- Node.js ---

parse_node_version_components() {
    if ! command -v node &> /dev/null; then
        return 1
    fi
    local version major minor
    version="$(node -v 2>/dev/null || true)"
    major="${version#v}"
    major="${major%%.*}"
    minor="${version#v}"
    minor="${minor#*.}"
    minor="${minor%%.*}"

    if [[ ! "$major" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    if [[ ! "$minor" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    echo "${major} ${minor}"
    return 0
}

node_major_version() {
    local version_components major minor
    version_components="$(parse_node_version_components || true)"
    read -r major minor <<< "$version_components"
    if [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]]; then
        echo "$major"
        return 0
    fi
    return 1
}

node_is_at_least_required() {
    local version_components major minor
    version_components="$(parse_node_version_components || true)"
    read -r major minor <<< "$version_components"
    if [[ ! "$major" =~ ^[0-9]+$ || ! "$minor" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    if [[ "$major" -gt "$NODE_MIN_MAJOR" ]]; then
        return 0
    fi
    if [[ "$major" -eq "$NODE_MIN_MAJOR" && "$minor" -ge "$NODE_MIN_MINOR" ]]; then
        return 0
    fi
    return 1
}

print_active_node_paths() {
    if ! command -v node &> /dev/null; then
        return 1
    fi
    local node_path node_version
    node_path="$(command -v node 2>/dev/null || true)"
    node_version="$(node -v 2>/dev/null || true)"
    ui_info "Active Node.js: ${node_version:-unknown} (${node_path:-unknown})"

    if command -v npm &> /dev/null; then
        local npm_path npm_version
        npm_path="$(command -v npm 2>/dev/null || true)"
        npm_version="$(npm -v 2>/dev/null || true)"
        ui_info "Active npm: ${npm_version:-unknown} (${npm_path:-unknown})"
    fi
    return 0
}

ensure_macos_node22_active() {
    if [[ "$OS" != "macos" ]]; then
        return 0
    fi

    local brew_node_prefix=""
    if command -v brew &> /dev/null; then
        brew_node_prefix="$(brew --prefix node@22 2>/dev/null || true)"
        if [[ -n "$brew_node_prefix" && -x "${brew_node_prefix}/bin/node" ]]; then
            export PATH="${brew_node_prefix}/bin:$PATH"
            refresh_shell_command_cache
        fi
    fi

    local major=""
    major="$(node_major_version || true)"
    if [[ -n "$major" && "$major" -ge 22 ]]; then
        return 0
    fi

    local active_path active_version
    active_path="$(command -v node 2>/dev/null || echo "not found")"
    active_version="$(node -v 2>/dev/null || echo "missing")"

    ui_error "Node.js v22 was installed but this shell is using ${active_version} (${active_path})"
    if [[ -n "$brew_node_prefix" ]]; then
        echo "Add this to your shell profile and restart shell:"
        echo "  export PATH=\"${brew_node_prefix}/bin:\$PATH\""
    else
        echo "Ensure Homebrew node@22 is first on PATH, then rerun installer."
    fi
    return 1
}

ensure_node22_active_shell() {
    if node_is_at_least_required; then
        return 0
    fi

    local active_path active_version
    active_path="$(command -v node 2>/dev/null || echo "not found")"
    active_version="$(node -v 2>/dev/null || echo "missing")"

    ui_error "Active Node.js must be v${NODE_MIN_VERSION}+ but this shell is using ${active_version} (${active_path})"
    print_active_node_paths || true

    local nvm_detected=0
    if [[ -n "${NVM_DIR:-}" || "$active_path" == *"/.nvm/"* ]]; then
        nvm_detected=1
    fi
    if command -v nvm >/dev/null 2>&1; then
        nvm_detected=1
    fi

    if [[ "$nvm_detected" -eq 1 ]]; then
        echo "nvm appears to be managing Node for this shell."
        echo "Run:"
        echo "  nvm install 22"
        echo "  nvm use 22"
        echo "  nvm alias default 22"
        echo "Then open a new shell and rerun:"
        echo "  curl -fsSL https://remoteclaw.org/install.sh | bash"
    else
        echo "Install/select Node.js 22+ and ensure it is first on PATH, then rerun installer."
    fi

    return 1
}

check_node() {
    if command -v node &> /dev/null; then
        if node_is_at_least_required; then
            ui_success "Node.js v$(node -v | cut -d'v' -f2) found"
            print_active_node_paths || true
            return 0
        else
            local nv
            nv="$(node_major_version || true)"
            if [[ -n "$nv" ]]; then
                ui_info "Node.js $(node -v) found, upgrading to v${NODE_MIN_VERSION}+"
            else
                ui_info "Node.js found but version could not be parsed; reinstalling v${NODE_MIN_VERSION}+"
            fi
            return 1
        fi
    else
        ui_info "Node.js not found, installing it now"
        return 1
    fi
}

install_node() {
    if [[ "$OS" == "macos" ]]; then
        ui_info "Installing Node.js via Homebrew"
        run_quiet_step "Installing node@22" brew install node@22
        brew link node@22 --overwrite --force 2>/dev/null || true
        if ! ensure_macos_node22_active; then
            exit 1
        fi
        ui_success "Node.js installed"
        print_active_node_paths || true
    elif [[ "$OS" == "linux" ]]; then
        require_sudo

        # Arch-based distros: use pacman
        if command -v pacman &> /dev/null || is_arch_linux; then
            ui_info "Installing Node.js via pacman (Arch-based distribution detected)"
            if is_root; then
                run_quiet_step "Installing Node.js" pacman -Sy --noconfirm nodejs npm
            else
                run_quiet_step "Installing Node.js" sudo pacman -Sy --noconfirm nodejs npm
            fi
            ui_success "Node.js installed"
            print_active_node_paths || true
            return 0
        fi

        ui_info "Installing Node.js via NodeSource"
        if command -v apt-get &> /dev/null; then
            local tmp
            tmp="$(mktempfile)"
            download_file "https://deb.nodesource.com/setup_22.x" "$tmp"
            if is_root; then
                run_quiet_step "Configuring NodeSource repository" bash "$tmp"
                run_quiet_step "Installing Node.js" apt-get install -y -qq nodejs
            else
                run_quiet_step "Configuring NodeSource repository" sudo -E bash "$tmp"
                run_quiet_step "Installing Node.js" sudo apt-get install -y -qq nodejs
            fi
        elif command -v dnf &> /dev/null; then
            local tmp
            tmp="$(mktempfile)"
            download_file "https://rpm.nodesource.com/setup_22.x" "$tmp"
            if is_root; then
                run_quiet_step "Configuring NodeSource repository" bash "$tmp"
                run_quiet_step "Installing Node.js" dnf install -y -q nodejs
            else
                run_quiet_step "Configuring NodeSource repository" sudo bash "$tmp"
                run_quiet_step "Installing Node.js" sudo dnf install -y -q nodejs
            fi
        elif command -v yum &> /dev/null; then
            local tmp
            tmp="$(mktempfile)"
            download_file "https://rpm.nodesource.com/setup_22.x" "$tmp"
            if is_root; then
                run_quiet_step "Configuring NodeSource repository" bash "$tmp"
                run_quiet_step "Installing Node.js" yum install -y -q nodejs
            else
                run_quiet_step "Configuring NodeSource repository" sudo bash "$tmp"
                run_quiet_step "Installing Node.js" sudo yum install -y -q nodejs
            fi
        else
            ui_error "Could not detect package manager"
            echo "Please install Node.js 22+ manually: https://nodejs.org"
            exit 1
        fi

        ui_success "Node.js installed"
        print_active_node_paths || true
    fi
}

# --- npm permissions (Linux) ---

fix_npm_permissions() {
    if [[ "$OS" != "linux" ]]; then
        return 0
    fi

    local npm_prefix
    npm_prefix="$(npm config get prefix 2>/dev/null || true)"
    if [[ -z "$npm_prefix" ]]; then
        return 0
    fi

    if [[ -w "$npm_prefix" || -w "$npm_prefix/lib" ]]; then
        return 0
    fi

    ui_info "Configuring npm for user-local installs"
    mkdir -p "$HOME/.npm-global"
    npm config set prefix "$HOME/.npm-global"

    # shellcheck disable=SC2016
    local path_line='export PATH="$HOME/.npm-global/bin:$PATH"'
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [[ -f "$rc" ]] && ! grep -q ".npm-global" "$rc"; then
            echo "$path_line" >> "$rc"
        fi
    done

    export PATH="$HOME/.npm-global/bin:$PATH"
    ui_success "npm configured for user installs"
}

# --- npm global bin ---

npm_global_bin_dir() {
    local prefix=""
    prefix="$(npm prefix -g 2>/dev/null || true)"
    if [[ -n "$prefix" && "$prefix" == /* ]]; then
        echo "${prefix%/}/bin"
        return 0
    fi

    prefix="$(npm config get prefix 2>/dev/null || true)"
    if [[ -n "$prefix" && "$prefix" != "undefined" && "$prefix" != "null" && "$prefix" == /* ]]; then
        echo "${prefix%/}/bin"
        return 0
    fi

    echo ""
    return 1
}

ensure_npm_global_bin_on_path() {
    local bin_dir=""
    bin_dir="$(npm_global_bin_dir || true)"
    if [[ -n "$bin_dir" ]]; then
        export PATH="${bin_dir}:$PATH"
    fi
}

path_has_dir() {
    local path="$1"
    local dir="${2%/}"
    if [[ -z "$dir" ]]; then
        return 1
    fi
    case ":${path}:" in
        *":${dir}:"*) return 0 ;;
        *) return 1 ;;
    esac
}

warn_shell_path_missing_dir() {
    local dir="${1%/}"
    local label="$2"
    if [[ -z "$dir" ]]; then
        return 0
    fi
    if path_has_dir "$ORIGINAL_PATH" "$dir"; then
        return 0
    fi

    echo ""
    ui_warn "PATH missing ${label}: ${dir}"
    echo "  This can make remoteclaw show as \"command not found\" in new terminals."
    echo "  Fix (zsh: ~/.zshrc, bash: ~/.bashrc):"
    echo "    export PATH=\"${dir}:\$PATH\""
}

# --- npm install ---

LAST_NPM_INSTALL_CMD=""

run_npm_global_install() {
    local spec="$1"
    local log="$2"
    local prefix_args=()

    if [[ "$LOCAL_INSTALL" == "1" ]]; then
        prefix_args=(--prefix "$HOME/.remoteclaw")
    fi

    local -a cmd
    cmd=(npm --loglevel "$NPM_LOGLEVEL" --no-fund --no-audit install -g ${prefix_args[@]+"${prefix_args[@]}"} "$spec")
    local cmd_display=""
    printf -v cmd_display '%q ' "${cmd[@]}"
    LAST_NPM_INSTALL_CMD="${cmd_display% }"

    if [[ "$VERBOSE" == "1" ]]; then
        "${cmd[@]}" 2>&1 | tee "$log"
        return $?
    fi

    "${cmd[@]}" >"$log" 2>&1
}

print_npm_failure_diagnostics() {
    local spec="$1"
    local log="$2"

    ui_warn "npm install failed for ${spec}"
    if [[ -n "${LAST_NPM_INSTALL_CMD}" ]]; then
        echo "  Command: ${LAST_NPM_INSTALL_CMD}"
    fi
    echo "  Installer log: ${log}"

    local error_code=""
    error_code="$(sed -n -E 's/^npm (ERR!|error) code[[:space:]]+([^[:space:]]+).*$/\2/p' "$log" | head -n1)"
    if [[ -n "$error_code" ]]; then
        echo "  npm code: ${error_code}"
    fi

    local debug_log=""
    debug_log="$(sed -n -E 's/.*A complete log of this run can be found in:[[:space:]]*//p' "$log" | tail -n1)"
    if [[ -n "$debug_log" ]]; then
        echo "  npm debug log: ${debug_log}"
    fi

    local first_error=""
    first_error="$(grep -E 'npm (ERR!|error)|ERR!' "$log" | head -n1 || true)"
    if [[ -n "$first_error" ]]; then
        echo "  First npm error: ${first_error}"
    fi
}

install_remoteclaw_npm() {
    local spec="$1"
    local log
    log="$(mktempfile)"
    if ! run_npm_global_install "$spec" "$log"; then
        print_npm_failure_diagnostics "$spec" "$log"

        if [[ "$VERBOSE" != "1" ]]; then
            ui_warn "npm install failed; showing last log lines"
            tail -n 40 "$log" >&2 || true
        fi
        return 1
    fi
    ui_success "RemoteClaw npm package installed"
    return 0
}

install_remoteclaw() {
    local install_spec="remoteclaw@${REMOTECLAW_VERSION}"

    local resolved_version=""
    resolved_version="$(npm view "${install_spec}" version 2>/dev/null || true)"
    if [[ -n "$resolved_version" ]]; then
        ui_info "Installing RemoteClaw v${resolved_version}"
    else
        ui_info "Installing RemoteClaw (${REMOTECLAW_VERSION})"
    fi

    if ! install_remoteclaw_npm "${install_spec}"; then
        return 1
    fi

    ui_success "RemoteClaw installed"
}

# --- Resolve binary ---

maybe_nodenv_rehash() {
    if command -v nodenv &> /dev/null; then
        nodenv rehash >/dev/null 2>&1 || true
    fi
}

resolve_remoteclaw_bin() {
    refresh_shell_command_cache
    local resolved=""
    resolved="$(type -P remoteclaw 2>/dev/null || true)"
    if [[ -n "$resolved" && -x "$resolved" ]]; then
        echo "$resolved"
        return 0
    fi

    if [[ "$LOCAL_INSTALL" == "1" ]]; then
        local local_bin="$HOME/.remoteclaw/bin/remoteclaw"
        if [[ -x "$local_bin" ]]; then
            echo "$local_bin"
            return 0
        fi
    fi

    ensure_npm_global_bin_on_path
    refresh_shell_command_cache
    resolved="$(type -P remoteclaw 2>/dev/null || true)"
    if [[ -n "$resolved" && -x "$resolved" ]]; then
        echo "$resolved"
        return 0
    fi

    local npm_bin=""
    npm_bin="$(npm_global_bin_dir || true)"
    if [[ -n "$npm_bin" && -x "${npm_bin}/remoteclaw" ]]; then
        echo "${npm_bin}/remoteclaw"
        return 0
    fi

    maybe_nodenv_rehash
    refresh_shell_command_cache
    resolved="$(type -P remoteclaw 2>/dev/null || true)"
    if [[ -n "$resolved" && -x "$resolved" ]]; then
        echo "$resolved"
        return 0
    fi

    echo ""
    return 1
}

warn_remoteclaw_not_found() {
    ui_warn "Installed, but remoteclaw is not discoverable on PATH in this shell"
    echo "  Try: hash -r (bash) or rehash (zsh), then retry."
    local t=""
    t="$(type -t remoteclaw 2>/dev/null || true)"
    if [[ "$t" == "alias" || "$t" == "function" ]]; then
        ui_warn "Found a shell ${t} named remoteclaw; it may shadow the real binary"
    fi
    if command -v nodenv &> /dev/null; then
        echo -e "Using nodenv? Run: ${INFO}nodenv rehash${NC}"
    fi

    local npm_bin=""
    npm_bin="$(npm_global_bin_dir 2>/dev/null || true)"
    if [[ -n "$npm_bin" ]]; then
        echo -e "npm bin -g: ${INFO}${npm_bin}${NC}"
        echo -e "If needed: ${INFO}export PATH=\"${npm_bin}:\\$PATH\"${NC}"
    fi
}

# --- Local install PATH setup ---

setup_local_path() {
    local target="$HOME/.remoteclaw/bin"
    mkdir -p "$target"

    export PATH="$target:$PATH"

    # shellcheck disable=SC2016
    local path_line='export PATH="$HOME/.remoteclaw/bin:$PATH"'
    for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
        if [[ -f "$rc" ]] && ! grep -q ".remoteclaw/bin" "$rc"; then
            echo "$path_line" >> "$rc"
        fi
    done
}

# --- CLI args ---

LOCAL_INSTALL=0
REMOTECLAW_VERSION=${REMOTECLAW_VERSION:-latest}
DRY_RUN=${REMOTECLAW_DRY_RUN:-0}
NPM_LOGLEVEL="${REMOTECLAW_NPM_LOGLEVEL:-error}"
VERBOSE="${REMOTECLAW_VERBOSE:-0}"
HELP=0

print_usage() {
    cat <<EOF
RemoteClaw installer (macOS + Linux)

Usage:
  curl -fsSL https://remoteclaw.org/install.sh | bash -s -- [options]

Options:
  --local                              Install to ~/.remoteclaw/bin (no root required)
  --version <version|dist-tag>         npm version to install (default: latest)
  --dry-run                            Print what would happen (no changes)
  --verbose                            Print debug output
  --help, -h                           Show this help

Environment variables:
  REMOTECLAW_VERSION=latest|<semver>   Version/tag to install
  REMOTECLAW_DRY_RUN=0|1              Dry run mode
  REMOTECLAW_VERBOSE=0|1              Verbose output
  REMOTECLAW_NPM_LOGLEVEL=error|warn  npm log level (default: error)

Examples:
  curl -fsSL https://remoteclaw.org/install.sh | bash
  curl -fsSL https://remoteclaw.org/install.sh | bash -s -- --local
  curl -fsSL https://remoteclaw.org/install.sh | bash -s -- --version 1.0.0
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --local)
                LOCAL_INSTALL=1
                shift
                ;;
            --version)
                REMOTECLAW_VERSION="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --verbose)
                VERBOSE=1
                shift
                ;;
            --help|-h)
                HELP=1
                shift
                ;;
            *)
                shift
                ;;
        esac
    done
}

configure_verbose() {
    if [[ "$VERBOSE" != "1" ]]; then
        return 0
    fi
    if [[ "$NPM_LOGLEVEL" == "error" ]]; then
        NPM_LOGLEVEL="notice"
    fi
    set -x
}

show_install_plan() {
    ui_section "Install plan"
    echo -e "${MUTED}OS:${NC} $OS"
    echo -e "${MUTED}Install mode:${NC} $(if [[ "$LOCAL_INSTALL" == "1" ]]; then echo "local (~/.remoteclaw/bin)"; else echo "global (npm -g)"; fi)"
    echo -e "${MUTED}Version:${NC} $REMOTECLAW_VERSION"
    if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "${MUTED}Dry run:${NC} yes"
    fi
}

# --- Main ---

main() {
    if [[ "$HELP" == "1" ]]; then
        print_usage
        return 0
    fi

    print_installer_banner
    detect_os_or_die

    show_install_plan

    if [[ "$DRY_RUN" == "1" ]]; then
        ui_success "Dry run complete (no changes made)"
        return 0
    fi

    # Check for existing installation
    local is_upgrade=false
    if [[ -n "$(type -P remoteclaw 2>/dev/null || true)" ]]; then
        ui_info "Existing RemoteClaw installation detected, upgrading"
        is_upgrade=true
    fi

    ui_stage "Preparing environment"

    # Homebrew (macOS only)
    if [[ "$LOCAL_INSTALL" != "1" ]]; then
        install_homebrew
    fi

    # Node.js
    if ! check_node; then
        if [[ "$LOCAL_INSTALL" == "1" && "$OS" == "macos" ]]; then
            install_homebrew
        fi
        install_node
    fi
    if ! ensure_node22_active_shell; then
        exit 1
    fi

    ui_stage "Installing RemoteClaw"

    if [[ "$LOCAL_INSTALL" == "1" ]]; then
        setup_local_path
    else
        # npm permissions (Linux)
        fix_npm_permissions
    fi

    # Install RemoteClaw
    install_remoteclaw

    ui_stage "Finalizing"

    local remoteclaw_bin=""
    remoteclaw_bin="$(resolve_remoteclaw_bin || true)"

    # PATH warnings
    if [[ "$LOCAL_INSTALL" == "1" ]]; then
        warn_shell_path_missing_dir "$HOME/.remoteclaw/bin" "local install dir (~/.remoteclaw/bin)"
    else
        local npm_bin=""
        npm_bin="$(npm_global_bin_dir || true)"
        warn_shell_path_missing_dir "$npm_bin" "npm global bin dir"
    fi

    echo ""
    local installed_version=""
    if [[ -n "$remoteclaw_bin" ]]; then
        installed_version="$("$remoteclaw_bin" --version 2>/dev/null | head -n 1 | tr -d '\r' || true)"
    fi

    if [[ -n "$installed_version" ]]; then
        ui_success "RemoteClaw installed successfully (${installed_version})!"
    else
        ui_success "RemoteClaw installed successfully!"
    fi

    if [[ -z "$remoteclaw_bin" ]]; then
        warn_remoteclaw_not_found
    fi

    if [[ "$is_upgrade" == "true" ]]; then
        echo -e "${MUTED}Upgrade complete. Open a new terminal if the command is not found.${NC}"
    else
        echo -e "${MUTED}Open a new terminal or run 'hash -r' to get started.${NC}"
    fi
    echo ""
}

parse_args "$@"
configure_verbose
main
