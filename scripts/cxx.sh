enable_crb_or_epel() {
    # Try to enable CRB (CodeReady Builder) or EPEL for ninja-build
    if command -v dnf >/dev/null 2>&1; then
        if ! dnf repolist enabled | grep -qE '^crb'; then
            log_info "尝试启用 CRB (CodeReady Builder) 软件源..."
            sudo_cmd dnf config-manager --set-enabled crb || true
        fi
    fi
    if ! rpm -q epel-release >/dev/null 2>&1; then
        log_info "尝试安装 EPEL 软件源..."
        sudo_cmd $PKG_MANAGER install -y epel-release || true
    fi
    pkg_makecache
}
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
TOOLS_DIR="${ASSETS_DIR}/tools"

PIPX_HOME="${PIPX_HOME:-$HOME/.local/pipx}"
PIPX_BIN_DIR="${PIPX_BIN_DIR:-$HOME/.local/bin}"

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

ensure_pipx() {
    if command -v pipx >/dev/null 2>&1; then
        return 0
    fi

    log_info "未检测到 pipx，尝试通过系统仓库安装..."
    pkg_makecache
    pkg_install pipx || true

    if ! command -v pipx >/dev/null 2>&1; then
        log_info "系统仓库未提供 pipx，尝试使用 pip (用户级) 安装..."
        if command -v python3 >/dev/null 2>&1; then
            python3 -m pip install --user -U pipx >/dev/null 2>&1 || \
                python3 -m pip install --user -U pipx --break-system-packages >/dev/null 2>&1 || true
        fi
        export PATH="$PIPX_BIN_DIR:$PATH"
    fi

    if ! command -v pipx >/dev/null 2>&1; then
        log_error "pipx 未安装，无法继续安装 conan。请先安装 pipx（推荐: sudo dnf install -y pipx）"
        exit 1
    fi
}

resolve_pipx_cmd() {
    export PIPX_HOME PIPX_BIN_DIR
    export PATH="$PIPX_BIN_DIR:$PATH"

    ensure_pipx

    local bashrc="$HOME/.bashrc"
    touch "$bashrc"
    log_info "写入 pipx 环境变量到 ${bashrc} ..."

    sed -i '/# pipx environment (managed by initializer)/d' "$bashrc" 2>/dev/null || true
    sed -i '/export PIPX_HOME=/d' "$bashrc" 2>/dev/null || true
    sed -i '/export PIPX_BIN_DIR=/d' "$bashrc" 2>/dev/null || true
    sed -i '/export PATH=.*PIPX_BIN_DIR/d' "$bashrc" 2>/dev/null || true

    cat >> "$bashrc" <<'EOF_PIPX'
# pipx environment (managed by initializer)
export PIPX_HOME="$HOME/.local/pipx"
export PIPX_BIN_DIR="$HOME/.local/bin"
export PATH="$PIPX_BIN_DIR:$PATH"
EOF_PIPX
}

install_cpp_toolchain() {
    show_step "安装 C/C++ 工具链"

    enable_crb_or_epel
    log_info "安装常用构建工具..."
    pkg_install \
        gcc gcc-c++ make cmake ninja-build \
        autoconf automake libtool \
        bison flex git \
        pkgconf-pkg-config \
        openssl-devel zlib-devel libcurl-devel \
        ca-certificates curl || log_warning "构建工具安装可能失败"
    log_success "C/C++ 工具链安装完成"
}

install_qt5() {
    show_step "安装 Qt5 开发包"

    pkg_makecache

    log_info "安装 Qt5 (qtbase/qttools/qml 等，按仓库实际可用包为准)..."
    local qt_pkgs=(
        qt5-qtbase-devel
        qt5-qttools-devel
        qt5-qtdeclarative-devel
        qt5-qtsvg-devel
        qt5-qtwebsockets-devel
        qt5-qtserialport-devel
        qt5-qtcharts-devel
        qt5-qtmultimedia-devel
        qt5-qtlocation-devel
        qt5-qtgraphicaleffects
    )
    local p
    for p in "${qt_pkgs[@]}"; do
        pkg_install "$p" >/dev/null 2>&1 || log_warning "安装失败: $p"
    done

    log_success "Qt5 安装流程结束"
}

install_xmake() {
    show_step "安装 xmake"

    if command -v xmake >/dev/null 2>&1; then
        log_info "xmake 已存在: $(xmake --version 2>/dev/null | head -n 1 || echo unknown)"
    fi

    local xmake_installer="${TOOLS_DIR}/xmake-v3.0.0.gz.run"
    if [ ! -f "$xmake_installer" ]; then
        log_warning "xmake 安装包不存在: $xmake_installer"
        return 0
    fi

    log_info "运行 xmake 安装器: $xmake_installer"
    chmod +x "$xmake_installer" || true
    "$xmake_installer" || log_warning "xmake 安装失败"

    if [ -f "$HOME/.local/bin/xmake" ]; then
        require_sudo
        if [ "$(id -u)" -eq 0 ]; then
            ln -sf "$HOME/.local/bin/xmake" /usr/local/bin/xmake || log_warning "无法创建 /usr/local/bin/xmake"
        else
            sudo ln -sf "$HOME/.local/bin/xmake" /usr/local/bin/xmake || log_warning "无法创建 /usr/local/bin/xmake"
        fi
        log_success "xmake 安装成功"
    else
        log_warning "未找到 $HOME/.local/bin/xmake，可能安装未完成"
    fi

    # 写入 XMAKE_ROOT 到 /etc/profile.d
    local profiled_xmake="/etc/profile.d/xmake.sh"
    require_sudo
    log_info "写入 XMAKE_ROOT 环境变量到 ${profiled_xmake} ..."

    if [ "$(id -u)" -eq 0 ]; then
        touch "$profiled_xmake" || true
        if ! grep -qE '^[[:space:]]*export[[:space:]]+XMAKE_ROOT=y[[:space:]]*$' "$profiled_xmake"; then
            cat >>"$profiled_xmake" <<'EOF_XMAKE'
# xmake environment (managed by initializer)
if [ -z "${XMAKE_ROOT:-}" ]; then
export XMAKE_ROOT=y
fi
EOF_XMAKE
        fi
        chmod a+r "$profiled_xmake" || log_warning "无法设置 ${profiled_xmake} 权限为可读"
    else
        sudo touch "$profiled_xmake" || true
        if ! sudo grep -qE '^[[:space:]]*export[[:space:]]+XMAKE_ROOT=y[[:space:]]*$' "$profiled_xmake"; then
            sudo tee -a "$profiled_xmake" >/dev/null <<'EOF_XMAKE'
# xmake environment (managed by initializer)
if [ -z "${XMAKE_ROOT:-}" ]; then
export XMAKE_ROOT=y
fi
EOF_XMAKE
        fi
        sudo chmod a+r "$profiled_xmake" || log_warning "无法设置 ${profiled_xmake} 权限为可读"
    fi

    export XMAKE_ROOT=y
}

install_vcpkg() {
    show_step "安装 vcpkg"

    if ! command -v git >/dev/null 2>&1; then
        log_warning "未检测到 git，尝试安装..."
        pkg_makecache
        pkg_install git || log_warning "git 安装失败"
    fi

    local vcpkg_dir="$HOME/.vcpkg"
    if [ ! -d "$vcpkg_dir" ]; then
        mkdir -p "$vcpkg_dir"
        chmod 755 "$vcpkg_dir" || true
        log_info "克隆 vcpkg 到 $vcpkg_dir ..."
        git clone https://github.com/Microsoft/vcpkg.git "$vcpkg_dir" || log_warning "vcpkg 克隆失败"
    else
        log_info "vcpkg 目录已存在: $vcpkg_dir"
    fi

    if [ -d "$vcpkg_dir" ]; then
        ( 
            cd "$vcpkg_dir"
            ./bootstrap-vcpkg.sh || log_warning "vcpkg 构建失败"
        )

        local bashrc="$HOME/.bashrc"
        touch "$bashrc"
        log_info "写入 vcpkg 环境变量到 ${bashrc} ..."

        sed -i '/# vcpkg environment/d' "$bashrc" 2>/dev/null || true
        sed -i '/export VCPKG_ROOT=/d' "$bashrc" 2>/dev/null || true
        sed -i '/export PATH=.*VCPKG_ROOT/d' "$bashrc" 2>/dev/null || true

        cat >> "$bashrc" <<EOF_VCPKG
# vcpkg environment (managed by initializer)
export VCPKG_ROOT="$vcpkg_dir"
export PATH="\$VCPKG_ROOT:\$PATH"
EOF_VCPKG

        export VCPKG_ROOT="$vcpkg_dir"
        export PATH="$VCPKG_ROOT:$PATH"

        if [ -f "$vcpkg_dir/vcpkg" ]; then
            log_success "vcpkg 安装成功"
            log_info "请运行 'source ~/.bashrc' 使环境变量生效"
        fi
    fi
}

install_conan() {
    show_step "安装 conan"

    resolve_pipx_cmd

    log_info "使用 pipx 安装 conan..."
    pipx install --force conan || log_warning "conan 安装失败 (pipx)"

    if command -v conan >/dev/null 2>&1; then
        log_success "conan 安装成功"
    else
        log_warning "conan 未出现在 PATH 中（可尝试: export PATH=\"$PIPX_BIN_DIR:\$PATH\" 或重新登录）"
    fi
}

main() {
    if [ "$(id -u)" -eq 0 ]; then
        log_warning "建议使用非 root 用户运行（脚本会用 sudo 安装系统依赖）"
    fi

    install_cpp_toolchain
    install_qt5
    install_xmake
    install_vcpkg
    install_conan

    log_success "C/C++ & Qt 开发环境安装完成"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
