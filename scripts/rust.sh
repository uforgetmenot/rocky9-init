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
        log_error "需要 sudo 以安装系统依赖，但未找到 sudo"
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
    if [ "${PKG_MANAGER}" = "none" ]; then
        log_error "未检测到 dnf/yum，无法安装系统依赖（需要 Rocky Linux 9 或其他 RHEL 系发行版）"
        exit 1
    fi
}

pkg_update_and_upgrade() {
    require_sudo
    ensure_pkg_manager
    show_step "更新系统仓库 (${PKG_MANAGER} makecache && ${PKG_MANAGER} upgrade)"

    sudo_cmd "${PKG_MANAGER}" -y makecache >/dev/null 2>&1 || log_warning "${PKG_MANAGER} makecache 可能失败"
    sudo_cmd "${PKG_MANAGER}" -y upgrade || log_warning "${PKG_MANAGER} upgrade 可能失败 (可稍后手动处理)"
}

pkg_install() {
    require_sudo
    ensure_pkg_manager
    sudo_cmd "${PKG_MANAGER}" -y install "$@" || return 1
}

ensure_curl() {
    show_step "安装 Curl"

    if command -v curl >/dev/null 2>&1; then
        log_info "检测到 curl 已安装: $(curl --version 2>/dev/null | head -n1 || echo unknown)"
        return 0
    fi

    pkg_install curl ca-certificates || {
        log_error "curl 安装失败"
        exit 1
    }
}

ensure_profile_env() {
    show_step "配置 Rust 环境到 ~/.profile"

    local profile="$HOME/.profile"
    local begin_mark="# rust environment (managed by initializer)"
    local end_mark="# /rust environment (managed by initializer)"

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

    cat >> "$profile" <<'EOF_RUST_ENV'
# rust environment (managed by initializer)
if [ -f "$HOME/.cargo/env" ]; then
    . "$HOME/.cargo/env"
fi
# /rust environment (managed by initializer)
EOF_RUST_ENV

    log_success "已写入 ~/.profile；可执行 'source ~/.profile' 使其在当前终端生效"
}

install_rust_with_rustup() {
    show_step "安装 Rust (rustup)"

    if command -v rustup >/dev/null 2>&1 && command -v rustc >/dev/null 2>&1; then
        log_info "检测到 Rust 已安装"
        return 0
    fi

    ensure_curl

    log_info "下载并运行 rustup 安装脚本 (非交互式默认安装)"
    # Reference: https://rust-lang.org/tools/install/
    # -y: default installation (stable)
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

    if [ ! -f "$HOME/.cargo/env" ]; then
        log_error "未找到 $HOME/.cargo/env，Rust 安装可能失败"
        exit 1
    fi
}

setup_rust_env_current_shell() {
    show_step "设置 Rust 环境 (当前 shell)"

    if [ -f "$HOME/.cargo/env" ]; then
        # shellcheck disable=SC1090
        . "$HOME/.cargo/env"
    fi

    export PATH="$HOME/.cargo/bin:$PATH"

    if ! command -v rustc >/dev/null 2>&1; then
        log_error "rustc 未正确加入 PATH；请执行 'source ~/.profile' 或重新登录"
        exit 1
    fi
}

verify_rust_installation() {
    show_step "验证 Rust 安装"

    log_info "rustc:  $(rustc --version 2>/dev/null || echo unknown)"
    log_info "cargo:  $(cargo --version 2>/dev/null || echo unknown)"
    log_info "rustup: $(rustup --version 2>/dev/null || echo unknown)"

    log_success "Rust 安装完成"
}

main() {
    pkg_update_and_upgrade
    install_rust_with_rustup
    ensure_profile_env
    setup_rust_env_current_shell
    verify_rust_installation
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
