#!/usr/bin/env bash
set -euo pipefail

# Simple logging helpers
_now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
show_step() { printf "\n==> %s\n" "$1"; }
log_info() { printf "%s [INFO] %s\n" "$(_now)" "$1"; }
log_warning() { printf "%s [WARN] %s\n" "$(_now)" "$1"; }
log_error() { printf "%s [ERROR] %s\n" "$(_now)" "$1"; }
log_success() { printf "%s [OK] %s\n" "$(_now)" "$1"; }

require_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        return 0
    fi
    if ! command -v sudo >/dev/null 2>&1; then
        log_error "需要 sudo 以安装到 /usr/local，但未找到 sudo"
        exit 1
    fi
}

sudo_cmd() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

detect_pkg_manager() {
    if command -v dnf >/dev/null 2>&1; then
        printf 'dnf'
    elif command -v yum >/dev/null 2>&1; then
        printf 'yum'
    else
        printf 'none'
    fi
}

PKG_MANAGER="$(detect_pkg_manager)"

ensure_pkg_manager() {
    if [ "$PKG_MANAGER" = "none" ]; then
        log_error "未检测到 dnf/yum，无法安装系统依赖（需要 Rocky Linux 9 或其他 RHEL 系发行版）"
        exit 1
    fi
}

pkg_makecache() {
    require_sudo
    ensure_pkg_manager
    sudo_cmd "$PKG_MANAGER" -y makecache >/dev/null 2>&1 || log_warning "${PKG_MANAGER} makecache 可能失败"
}

pkg_install() {
    require_sudo
    ensure_pkg_manager
    sudo_cmd "$PKG_MANAGER" -y install "$@" || return 1
}

resolve_go_arch() {
    local machine
    machine="$(uname -m)"
    case "$machine" in
        x86_64|amd64)
            printf 'amd64'
            ;;
        aarch64|arm64)
            printf 'arm64'
            ;;
        *)
            return 1
            ;;
    esac
}

fetch_latest_go_version() {
    # Returns like: go1.24.2
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "https://go.dev/VERSION?m=text" | head -n1
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- "https://go.dev/VERSION?m=text" | head -n1
    else
        return 1
    fi
}

ensure_profile_env() {
    show_step "配置 Go 环境变量到 ~/.profile"

    local profile="$HOME/.profile"
    local begin_mark="# go environment (managed by initializer)"
    local end_mark="# /go environment (managed by initializer)"

    touch "$profile"

    if grep -qF "$begin_mark" "$profile" 2>/dev/null; then
        local tmp
        tmp="$(mktemp)"
        awk -v b="$begin_mark" -v e="$end_mark" '
            $0==b {inblock=1; next}
            $0==e {inblock=0; next}
            !inblock {print}
        ' "$profile" > "$tmp" && mv "$tmp" "$profile" || rm -f "$tmp"
    fi

    cat >> "$profile" <<'EOF_GO_ENV'
# go environment (managed by initializer)
export GOROOT=/usr/local/go
export GOPATH=$HOME/go
export PATH=$GOPATH/bin:$GOROOT/bin:$PATH
# /go environment (managed by initializer)
EOF_GO_ENV

    log_success "已写入 ~/.profile；可执行 'source ~/.profile' 使其在当前终端生效"
}

install_golang() {
    show_step "安装 Go (官方分发版)"

    local arch
    if ! arch="$(resolve_go_arch)"; then
        log_error "不支持的架构: $(uname -m)"
        exit 1
    fi

    # Ensure download/extract tools exist
    local need_pkgs=()
    command -v tar >/dev/null 2>&1 || need_pkgs+=(tar)
    command -v gzip >/dev/null 2>&1 || need_pkgs+=(gzip)
    command -v ca-certificates >/dev/null 2>&1 || true
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        need_pkgs+=(curl)
    fi

    if [ "${#need_pkgs[@]}" -gt 0 ]; then
        log_info "安装依赖: ${need_pkgs[*]}"
        pkg_makecache
        pkg_install "${need_pkgs[@]}" || log_warning "依赖安装可能失败: ${need_pkgs[*]}"
    fi

    local version
    if ! version="$(fetch_latest_go_version)"; then
        log_error "无法获取 Go 最新版本号 (需要 curl 或 wget)"
        exit 1
    fi

    if ! printf '%s' "$version" | grep -Eq '^go[0-9]+\.[0-9]+(\.[0-9]+)?$'; then
        log_error "获取到的版本号异常: $version"
        exit 1
    fi

    local url="https://go.dev/dl/${version}.linux-${arch}.tar.gz"
    local tmpdir
    tmpdir="$(mktemp -d)"
    local tarball="${tmpdir}/${version}.linux-${arch}.tar.gz"

    local current_ver=""
    if [ -x "/usr/local/go/bin/go" ]; then
        current_ver="$(/usr/local/go/bin/go version 2>/dev/null | awk '{print $3}' || true)"
    fi

    if [ -n "$current_ver" ] && [ "$current_ver" = "$version" ]; then
        log_info "检测到 Go 已是最新版本: $current_ver，跳过安装包下载与解压"
    else
        log_info "下载: $url"

        if command -v curl >/dev/null 2>&1; then
            curl -fL --retry 3 --retry-delay 1 -o "$tarball" "$url" || true
        else
            wget -qO "$tarball" "$url" || true
        fi

        if [ ! -s "$tarball" ]; then
            log_error "下载失败或文件为空: $tarball"
            rm -rf "$tmpdir"
            exit 1
        fi

        require_sudo
        log_info "安装到 /usr/local/go (将覆盖旧版本)"
        sudo_cmd rm -rf /usr/local/go
        sudo_cmd tar -C /usr/local -xzf "$tarball"
    fi

    rm -rf "$tmpdir"

    # Create GOPATH structure (recommended)
    mkdir -p "$HOME/go" "$HOME/go/bin" "$HOME/go/pkg" "$HOME/go/src"

    ensure_profile_env

    # Make available in current shell session
    export GOROOT=/usr/local/go
    export GOPATH="$HOME/go"
    export PATH="$GOPATH/bin:$GOROOT/bin:$PATH"

    if ! command -v go >/dev/null 2>&1; then
        log_error "go 未正确加入 PATH；请执行 'source ~/.profile' 或重新登录"
        exit 1
    fi

    log_info "go version: $(go version 2>/dev/null || echo 未知)"
    log_info "GOROOT: ${GOROOT}"
    log_info "GOPATH: ${GOPATH}"

    log_success "Go 安装完成"
}

main() {
    install_golang
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
