#!/usr/bin/env bash
set -euo pipefail

# Simple logging helpers
_now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
show_step() { printf "\n==> %s\n" "$1"; }
log_info() { printf "%s [INFO] %s\n" "$(_now)" "$1"; }
log_warning() { printf "%s [WARN] %s\n" "$(_now)" "$1"; }
log_error() { printf "%s [ERROR] %s\n" "$(_now)" "$1"; }
log_success() { printf "%s [OK] %s\n" "$(_now)" "$1"; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

detect_pkg_manager() {
    if command_exists dnf; then
        printf 'dnf'
    elif command_exists yum; then
        printf 'yum'
    else
        printf 'none'
    fi
}

PKG_MANAGER="$(detect_pkg_manager)"

sudo_cmd() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        if ! command_exists sudo; then
            return 1
        fi
        sudo "$@"
    fi
}

pkg_makecache() {
    if [ "${PKG_MANAGER}" = "none" ]; then
        return 1
    fi
    sudo_cmd "${PKG_MANAGER}" -y makecache >/dev/null 2>&1 || true
}

pkg_install() {
    if [ "${PKG_MANAGER}" = "none" ]; then
        return 1
    fi
    sudo_cmd "${PKG_MANAGER}" -y install "$@" || return 1
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP_VENV_DIR="$HOME/.local/mcp-venv"

PIPX_HOME="${PIPX_HOME:-$HOME/.local/pipx}"
PIPX_BIN_DIR="${PIPX_BIN_DIR:-$HOME/.local/bin}"

install_uvx() {
    show_step "安装 uvx"

    if command -v uvx >/dev/null 2>&1; then
        log_info "uvx 已存在，跳过安装"
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        log_error "未检测到 curl，无法下载安装脚本"
        exit 1
    fi

    log_info "通过官方安装脚本安装 uv..."
    if curl -fsSL https://astral.sh/uv/install.sh | sh; then
        export PATH="$HOME/.local/bin:$PATH"
        log_success "uvx 安装完成"
    else
        log_error "uvx 安装失败"
        exit 1
    fi
}

ensure_pipx() {
    if command -v pipx >/dev/null 2>&1; then
        return 0
    fi

    log_info "未检测到 pipx，尝试通过系统仓库安装..."
    pkg_makecache || true
    pkg_install pipx || true

    if ! command -v pipx >/dev/null 2>&1; then
        log_info "系统仓库未提供 pipx，尝试使用 pip (用户级) 安装..."
        if command_exists python3; then
            python3 -m pip install --user -U pipx >/dev/null 2>&1 || \
                python3 -m pip install --user -U pipx --break-system-packages >/dev/null 2>&1 || true
            export PATH="$PIPX_BIN_DIR:$PATH"
        fi
    fi

    if ! command -v pipx >/dev/null 2>&1; then
        log_error "pipx 未安装，无法继续安装 Python MCP 包。请先安装 pipx（推荐: sudo dnf install -y pipx）"
        exit 1
    fi
}

resolve_pipx_cmd() {
    export PIPX_HOME PIPX_BIN_DIR
    export PATH="$PIPX_BIN_DIR:$PATH"

    if [ -n "${PIPX_CMD:-}" ]; then
        # shellcheck disable=SC2206
        PIPX_CMD_ARR=(${PIPX_CMD})
        return 0
    fi

    ensure_pipx
    PIPX_CMD_ARR=(pipx)

    # Ensure pipx's binary dir is on PATH for current shell.
    export PATH="$PIPX_BIN_DIR:$PATH"
}

install_mcp() {
    show_step "安装 MCP 相关依赖"

    if ! command -v npm >/dev/null 2>&1; then
        log_error "未检测到 npm，请先安装 Node.js 环境"
        exit 1
    fi

    local npm_registry="https://registry.npmmirror.com"
    local npm_pkgs=(
        "@playwright/mcp@latest"
        "@modelcontextprotocol/server-sequential-thinking"
        "@modelcontextprotocol/server-memory"
        "@modelcontextprotocol/server-filesystem"
        "mcp-mongo-server"
        "@modelcontextprotocol/server-redis"
        "@upstash/context7-mcp"
        "@modelcontextprotocol/server-puppeteer"
        "firecrawl-mcp"
        "@agentdeskai/browser-tools-mcp@latest"
        "chrome-devtools-mcp@latest"
    )

    log_info "通过 npm 安装 MCP 相关包..."
    for pkg in "${npm_pkgs[@]}"; do
        log_info "安装 npm 包: $pkg"
        npm install -g "$pkg" --registry="$npm_registry" || log_warning "安装失败: $pkg"
    done

    resolve_pipx_cmd
    log_info "使用 pipx 命令: ${PIPX_CMD_ARR[*]}"

    local pip_pkgs=(
        "mcp-server-time"
        "mcp-server-fetch"
        "mcp-server-sqlite"
        "mysql-mcp-server"
        "mcp-server-qdrant"
    )

    for pkg in "${pip_pkgs[@]}"; do
        log_info "安装 pipx 包: $pkg"
        "${PIPX_CMD_ARR[@]}" install --force "$pkg" || log_warning "安装失败: $pkg"
    done

    log_success "MCP 依赖安装完成"
}

main() {
    install_uvx
    install_mcp
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
