#!/usr/bin/env bash
set -euo pipefail

# Simple logging helpers
_now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
show_step() { printf "\n==> %s\n" "$1"; }
log_info() { printf "%s [INFO] %s\n" "$(_now)" "$1"; }
log_warning() { printf "%s [WARN] %s\n" "$(_now)" "$1"; }
log_error() { printf "%s [ERROR] %s\n" "$(_now)" "$1"; }
log_success() { printf "%s [OK] %s\n" "$(_now)" "$1"; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS_DIR="$(cd "${ROOT_DIR}/../assets" && pwd)"

install_nodejs() {
    show_step "安装 Node.js"

    local node_pkg="${ASSETS_DIR}/node-v22.18.0-linux-x64.tar.xz"
    local install_base="$HOME/.local"
    local target_dir="$install_base/node-v22.18.0-linux-x64"
    local node_link="$install_base/node"
    local bashrc="$HOME/.bashrc"

    if [ ! -f "$node_pkg" ]; then
        log_error "未找到 Node.js 安装包: $node_pkg"
        exit 1
    fi

    mkdir -p "$install_base" "$HOME/.local/bin"

    if [ ! -d "$target_dir" ]; then
        log_info "解压 Node.js 到 ${install_base} ..."
        tar -xJf "$node_pkg" -C "$install_base" || log_error "Node.js 解压失败"
    else
        log_info "检测到已解压的 Node.js 目录，跳过解压"
    fi

    ln -sfn "$target_dir" "$node_link"

    # 写入 PATH（用户级）
    touch "$bashrc"
    sed -i '/# node environment (managed by initializer)/d' "$bashrc" 2>/dev/null || true
    sed -i '/export NODE_HOME=/d' "$bashrc" 2>/dev/null || true
    sed -i '/export PATH=.*NODE_HOME/d' "$bashrc" 2>/dev/null || true
    cat >> "$bashrc" <<'EOF_NODE'
# node environment (managed by initializer)
export NODE_HOME="$HOME/.local/node"
export PATH="$NODE_HOME/bin:$HOME/.local/bin:$HOME/.npm-global/bin/:$PATH"
EOF_NODE

    # 立刻生效当前会话
    export NODE_HOME="$node_link"
    export PATH="$NODE_HOME/bin:$HOME/.local/bin:$HOME/.npm-global/bin/:$PATH"

    if ! command -v node >/dev/null 2>&1; then
        log_error "Node.js 未正确加入 PATH"
    fi

    log_info "Node 版本: $(node -v 2>/dev/null || echo 未知)"
    log_info "NPM  版本: $(npm -v 2>/dev/null || echo 未知)"

    # 设置 npm 镜像源
    log_info "配置 npm 镜像为 https://registry.npmmirror.com ..."
    npm config set registry https://registry.npmmirror.com --location=global 2>/dev/null || \
    npm config set registry https://registry.npmmirror.com -g 2>/dev/null || true


    # 直接用 npm 安装 yarn 和 pnpm，并配置镜像
    log_info "全局安装 Yarn 和 Pnpm ..."
    npm install -g yarn pnpm --registry=https://registry.npmmirror.com || log_warning "Yarn/Pnpm 安装失败"

    # 配置 yarn 镜像
    if command -v yarn >/dev/null 2>&1; then
        yarn config set npmRegistryServer https://registry.npmmirror.com -H >/dev/null 2>&1 || \
        yarn config set registry https://registry.npmmirror.com >/dev/null 2>&1 || true
        log_info "Yarn 版本: $(yarn -v 2>/dev/null || echo 未知)"
    else
        log_warning "Yarn 未安装或未激活"
    fi

    # 配置 pnpm 镜像
    if command -v pnpm >/dev/null 2>&1; then
        pnpm config set registry https://registry.npmmirror.com --global >/dev/null 2>&1 || true
        log_info "pnpm 版本: $(pnpm -v 2>/dev/null || echo 未知)"
    else
        log_warning "pnpm 未安装或未激活"
    fi

    log_success "Node.js/npm/yarn/pnpm 安装与镜像配置完成。请运行 'source ~/.bashrc' 使环境变量生效"
}

main() {
    install_nodejs
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
