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

require_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        return 0
    fi
    if ! command_exists sudo; then
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
    if command_exists dnf; then
        printf 'dnf'
    elif command_exists yum; then
        printf 'yum'
    else
        printf 'none'
    fi
}

PKG_MANAGER="$(detect_pkg_manager)"

ensure_pkg_manager() {
    if [ "${PKG_MANAGER}" = "none" ]; then
        log_error "未检测到 dnf/yum，无法安装 Docker（需要 Rocky Linux 9 或其他 RHEL 系发行版）"
        exit 1
    fi
}

get_os_release_field() {
    local key="$1"
    awk -F= -v k="$key" '$1==k {gsub(/^"/, "", $2); gsub(/"$/, "", $2); print $2; exit}' /etc/os-release 2>/dev/null || true
}

is_rhel_like() {
    local id like
    id="$(get_os_release_field ID)"
    like="$(get_os_release_field ID_LIKE)"

    case "${id}" in
        rocky|rhel|centos|almalinux|ol) return 0 ;;
    esac

    [[ "${like}" == *rhel* ]] && return 0
    return 1
}

add_docker_ce_repo() {
    show_step "添加 Docker CE 官方仓库"

    if [ -f /etc/yum.repos.d/docker-ce.repo ]; then
        log_info "已存在 /etc/yum.repos.d/docker-ce.repo，跳过添加"
        return 0
    fi

    pkg_makecache
    pkg_install dnf-plugins-core >/dev/null 2>&1 || pkg_install yum-utils >/dev/null 2>&1 || true

    if command_exists dnf && dnf config-manager --help >/dev/null 2>&1; then
        sudo_cmd dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo >/dev/null 2>&1 || return 1
    elif command_exists yum-config-manager; then
        sudo_cmd yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo >/dev/null 2>&1 || return 1
    else
        return 1
    fi

    pkg_makecache
    log_success "Docker CE 仓库已添加"
}

pkg_makecache() {
    require_sudo
    ensure_pkg_manager
    sudo_cmd "${PKG_MANAGER}" -y makecache >/dev/null 2>&1 || log_warning "${PKG_MANAGER} makecache 可能失败"
}

pkg_install() {
    require_sudo
    ensure_pkg_manager
    sudo_cmd "${PKG_MANAGER}" -y install "$@" || return 1
}

install_docker() {
    show_step "安装 Docker"

    if command -v docker &>/dev/null; then
        log_info "Docker 已安装: $(docker --version)"
        return 0
    fi

    log_info "开始安装 Docker..."
    pkg_makecache

    log_info "尝试从系统仓库安装 Docker（若失败将尝试添加 Docker CE 官方仓库）..."
    if pkg_install docker docker-compose-plugin; then
        :
    elif pkg_install docker docker-compose; then
        :
    elif pkg_install docker-engine docker-compose; then
        :
    elif pkg_install moby-engine moby-cli containerd; then
        :
    else
        if is_rhel_like && add_docker_ce_repo; then
            log_info "从 Docker CE 仓库安装 docker-ce..."
            pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || {
                log_error "Docker CE 安装失败"
                log_info "可尝试手动检查可用包：${PKG_MANAGER} search docker-ce"
                exit 1
            }
        else
            log_error "Docker 安装失败：系统仓库未找到可用的 Docker 相关包，且无法自动添加 Docker CE 仓库"
            log_info "可尝试手动检查可用包：${PKG_MANAGER} search docker"
            exit 1
        fi
    fi

    log_success "Docker 安装完成: $(docker --version)"
}

configure_docker() {
    show_step "配置 Docker"

    local daemon_json="/etc/docker/daemon.json"
    local backup_json="${daemon_json}.backup.$(date +%Y%m%d_%H%M%S)"

    # 备份现有配置
    if [ -f "$daemon_json" ]; then
        log_info "备份现有配置到: $backup_json"
        sudo_cmd cp "$daemon_json" "$backup_json"
    fi

    # 创建配置目录
    sudo_cmd mkdir -p /etc/docker

    # 写入配置
    log_info "配置 insecure-registries..."
    cat <<'EOF' | sudo_cmd tee "$daemon_json" > /dev/null
{
  "insecure-registries": [
    "127.0.0.1:5000",
    "core.yuhuans.cn:5000"
  ],
  "registry-mirrors": [],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

    log_success "Docker 配置文件已更新: $daemon_json"
}

add_user_to_docker_group() {
    show_step "添加用户到 Docker 组"

    local username="${SUDO_USER:-$(whoami)}"

    if ! getent group docker >/dev/null 2>&1; then
        log_info "创建 docker 组..."
        sudo_cmd groupadd -r docker >/dev/null 2>&1 || true
    fi

    if groups "$username" | grep -q '\bdocker\b'; then
        log_info "用户 $username 已在 docker 组中"
        return 0
    fi

    log_info "添加用户 $username 到 docker 组..."
    sudo_cmd usermod -aG docker "$username"

    log_success "用户 $username 已添加到 docker 组"
    log_warning "需要重新登录或执行 'newgrp docker' 使组权限生效"
}

start_docker_service() {
    show_step "启动 Docker 服务"

    log_info "重启 Docker 服务以应用配置..."
    sudo_cmd systemctl daemon-reload >/dev/null 2>&1 || true
    sudo_cmd systemctl restart docker || true
    sudo_cmd systemctl enable docker || true

    log_success "Docker 服务已启动并设置为开机自启"
}

verify_docker() {
    show_step "验证 Docker 安装"

    log_info "Docker 版本:"
    docker --version

    log_info "Docker Compose 版本:"
    if docker compose version >/dev/null 2>&1; then
        docker compose version
    elif command_exists docker-compose; then
        docker-compose version
    else
        log_warning "未找到 docker compose / docker-compose"
    fi

    log_info "Docker 服务状态:"
    sudo_cmd systemctl status docker --no-pager 2>/dev/null | head -n 5 || true

    log_info "Docker 配置:"
    sudo_cmd cat /etc/docker/daemon.json 2>/dev/null || true

    log_success "Docker 安装和配置验证完成"
}

main() {
    show_step "开始安装和配置 Docker"

    install_docker
    configure_docker
    add_user_to_docker_group
    start_docker_service
    verify_docker

    show_step "Docker 安装和配置完成!"
    log_info "提示: 如果无法使用 docker 命令，请重新登录或执行 'newgrp docker'"
}

main "$@"
