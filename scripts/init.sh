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

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "请使用 sudo 运行 init 脚本（例如: sudo INIT_USERNAME=$(id -un) scripts/init.sh）"
        exit 1
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
        log_error "未检测到 dnf/yum，无法安装系统依赖（需要 Rocky Linux 9 或其他 RHEL 系发行版）"
        exit 1
    fi
}

pkg_makecache() {
    ensure_pkg_manager
    "${PKG_MANAGER}" -y makecache >/dev/null 2>&1 || log_warning "${PKG_MANAGER} makecache 可能失败"
}

pkg_install() {
    ensure_pkg_manager
    "${PKG_MANAGER}" -y install "$@" || return 1
}

pkg_group_install() {
    ensure_pkg_manager
    "${PKG_MANAGER}" -y groupinstall "$@" || return 1
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${ROOT_DIR}/.." && pwd)"
ASSETS_DIR="${REPO_ROOT}/assets"
TOOLS_DIR="${ASSETS_DIR}/tools"

trap 'log_error "Script failed at line ${LINENO}"' ERR

resolve_username() {
    # INIT_USERNAME>USERNAME envs take precedence; fall back to first arg
    USERNAME="${INIT_USERNAME:-${USERNAME:-${1:-}}}"
    if [ -z "${USERNAME:-}" ]; then
        log_error "未提供目标用户名 (INIT_USERNAME/USERNAME/参数)"
        exit 1
    fi

    if ! id -u "$USERNAME" >/dev/null 2>&1; then
        log_error "用户不存在: $USERNAME"
        exit 1
    fi
}

configure_user_privileges() {
    show_step "配置用户组与 sudo 权限"

    local groups_to_add=(wheel adm users)
    local group
    for group in "${groups_to_add[@]}"; do
        if ! getent group "$group" >/dev/null 2>&1; then
            continue
        fi
        if ! id -nG "$USERNAME" 2>/dev/null | tr ' ' '\n' | grep -qx "$group"; then
            log_info "将用户 ${USERNAME} 添加到 ${group} 组..."
            usermod -aG "$group" "$USERNAME" || log_warning "添加到 ${group} 组失败"
        fi
    done

    local sudoers_file="/etc/sudoers.d/${USERNAME}"
    log_info "为用户 ${USERNAME} 配置免密sudo: ${sudoers_file}"

    cat <<EOF > "$sudoers_file"
${USERNAME} ALL=(ALL) NOPASSWD: ALL
EOF

    chmod 0440 "$sudoers_file"

    if command_exists visudo && visudo -c >/dev/null 2>&1; then
        log_success "sudoers 配置校验通过"
    else
        log_warning "sudoers 配置校验未通过或 visudo 不可用，请检查 ${sudoers_file}"
    fi
}


install_basic_packages() {
    show_step "安装基础软件包"

    pkg_makecache

    log_info "安装核心工具包..."
    pkg_install \
        tar unzip xz zip jq coreutils findutils \
        curl wget ca-certificates gnupg2 git \
        lsof qrencode gzip \
        python3 python3-pip python3-devel \
        openssl openssl-devel \
        || log_warning "部分基础包安装失败"

    log_info "安装常见开发工具链（Development Tools）..."
    pkg_group_install "Development Tools" || log_warning "组包 Development Tools 安装失败（可忽略或手动安装 gcc/make 等）"

    # 兜底：确保关键构建依赖存在
    pkg_install \
        gcc gcc-c++ make cmake ninja-build \
        autoconf automake libtool bison flex pkgconf-pkg-config \
        zlib-devel libcurl-devel \
        || log_warning "部分构建依赖安装失败"

    # locate/updatedb：不同发行版可能是 mlocate 或 plocate
    if ! command -v updatedb >/dev/null 2>&1; then
        pkg_install plocate || pkg_install mlocate || true
    fi

    # 配置 mlocate 忽略路径
    UPDATEDB_CONF="/etc/updatedb.conf"
    if [ -w "$UPDATEDB_CONF" ] || [ ! -f "$UPDATEDB_CONF" ]; then
        touch "$UPDATEDB_CONF" && chmod 644 "$UPDATEDB_CONF" || true
        tmpfile="$(mktemp)"
        awk '
BEGIN {
    found = 0
}
{
    if ($0 ~ /^[[:space:]]*PRUNEPATHS=/ && $0 !~ /^[[:space:]]*#/) {
        found = 1
        paths = ""
        # 提取双引号内的内容（不依赖 match 的数组参数，兼容最小 awk）
        if (match($0, /PRUNEPATHS="[^"]*"/)) {
            paths = substr($0, RSTART + 11, RLENGTH - 12)
        }
        if (paths !~ /(^|[[:space:]])\/mnt([[:space:]]|$)/) {
            paths = paths " /mnt"
        }
        if (paths !~ /(^|[[:space:]])\/tmp([[:space:]]|$)/) {
            paths = paths " /tmp"
        }
        gsub(/[[:space:]]+/, " ", paths)
        sub(/^[[:space:]]+/, "", paths)
        print "PRUNEPATHS=\"" paths "\""
        next
    }
    print
}
END {
    if (found == 0) {
        print "PRUNEPATHS=\"/tmp /mnt\""
    }
}
' "$UPDATEDB_CONF" > "$tmpfile" && mv "$tmpfile" "$UPDATEDB_CONF" || rm -f "$tmpfile"
    fi

    updatedb || log_warning "updatedb 执行失败"
    log_success "基础软件包安装完成"
}


disable_automatic_updates() {
    show_step "禁用系统自动更新 (DNF/YUM)"

    if ! command_exists systemctl; then
        log_warning "未检测到 systemctl，跳过自动更新服务配置"
        return 0
    fi

    local units=(
        dnf-automatic.timer
        dnf-automatic.service
        dnf-makecache.timer
        dnf-makecache.service
        yum-cron.timer
        yum-cron.service
    )

    local u
    for u in "${units[@]}"; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^${u}"; then
            systemctl stop "$u" >/dev/null 2>&1 || true
            systemctl disable "$u" >/dev/null 2>&1 || true
            [[ "$u" == *.service ]] && systemctl mask "$u" >/dev/null 2>&1 || true
        fi
    done

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed >/dev/null 2>&1 || true

    log_success "自动更新相关服务已禁用（如存在）"
}


setup_repositories() {
    show_step "配置软件源 (Rocky Linux DNF/YUM)"

    if [ "${SKIP_ROCKY_REPO_MIRROR:-}" = "1" ]; then
        log_info "已设置 SKIP_ROCKY_REPO_MIRROR=1，跳过软件源修改"
        pkg_makecache
        return 0
    fi

    local mirror="${ROCKY_REPO_MIRROR:-https://mirrors.aliyun.com/rockylinux}"
    local repo_dir="/etc/yum.repos.d"

    if [ ! -d "$repo_dir" ]; then
        log_warning "未找到 $repo_dir，跳过软件源修改"
        pkg_makecache
        return 0
    fi

    local changed=false
    local repo_file
    for repo_file in "$repo_dir"/*.repo; do
        [ -f "$repo_file" ] || continue

        if [ ! -f "${repo_file}.backup" ]; then
            cp "$repo_file" "${repo_file}.backup" || true
        fi

        if grep -Eq 'rockylinux|dl\.rockylinux\.org|mirrors\.rockylinux\.org|download\.rockylinux\.org' "$repo_file" 2>/dev/null; then
            # Rocky repo 文件通常使用 mirrorlist，切换到固定镜像时需要禁用 mirrorlist 并启用 baseurl。
            sed -i \
                -e 's/^[[:space:]]*metalink=/#metalink=/g' \
                -e 's/^[[:space:]]*mirrorlist=/#mirrorlist=/g' \
                -e 's/^[[:space:]]*#baseurl=/baseurl=/g' \
                -e 's#https\?://dl\.rockylinux\.org/\$contentdir#'"${mirror}"'#g' \
                -e 's#https\?://download\.rockylinux\.org/\$contentdir#'"${mirror}"'#g' \
                "$repo_file" || true
            changed=true
        fi
    done

    pkg_makecache

    if [ "$changed" = true ]; then
        log_success "软件源镜像已尝试切换为: ${mirror}"
    else
        log_info "未检测到 Rocky Linux 相关 repo 配置，保持当前软件源不变"
    fi
}


setup_python() {
    show_step "配置 Python 环境"

    if command -v python3 &> /dev/null; then
        PYTHON_VERSION=$(python3 --version | cut -d' ' -f2 | cut -d'.' -f1,2)
        log_info "当前Python版本: $PYTHON_VERSION"
    fi

    log_info "尝试安装 Python 3..."
    pkg_install python3 python3-devel python3-pip || {
        log_warning "Python 3 安装失败，使用系统默认Python版本"
    }

    log_info "配置 pip 阿里云镜像源..."

    # system-wide pip config (affects root/venv installs)
    cat > /etc/pip.conf << 'EOF'
[global]
index-url=https://mirrors.aliyun.com/pypi/simple/
disable-pip-version-check=true
timeout=120

[install]
trusted-host=mirrors.aliyun.com
EOF
    chmod 644 /etc/pip.conf || true

    # user-level pip config (target user)
    local user_home
    user_home="$(getent passwd "$USERNAME" 2>/dev/null | cut -d: -f6 || true)"
    if [ -n "${user_home}" ] && [ -d "${user_home}" ]; then
        mkdir -p "${user_home}/.pip"
        cp -f /etc/pip.conf "${user_home}/.pip/pip.conf" || true
        chown -R "${USERNAME}:${USERNAME}" "${user_home}/.pip" >/dev/null 2>&1 || true
    fi

    EXTERNALLY_MANAGED_FILE=$(python3 -c 'import sysconfig,os;print(os.path.join(sysconfig.get_paths()["purelib"],"EXTERNALLY-MANAGED"))' 2>/dev/null || echo /nonexistent)
    PIP_CMD=(python3 -m pip)
    PY_VENV_DIR="/opt/initializer-venv"
    if [ -f "$EXTERNALLY_MANAGED_FILE" ]; then
        log_info "检测到 PEP 668 受管环境，创建虚拟环境: $PY_VENV_DIR"
        if [ ! -d "$PY_VENV_DIR" ]; then
            python3 -m venv "$PY_VENV_DIR" || log_error "虚拟环境创建失败"
        fi
        PIP_CMD=("$PY_VENV_DIR/bin/pip")
        log_info "升级虚拟环境 pip/setuptools/wheel..."
        "${PIP_CMD[@]}" install -U -i https://mirrors.aliyun.com/pypi/simple/ \
            --trusted-host mirrors.aliyun.com \
            --no-input \
            --upgrade pip wheel setuptools || log_warning "虚拟环境基础组件升级失败"
        cat > /etc/profile.d/initializer_python.sh <<EOF_PYENV
# initializer python venv
if [ -d "$PY_VENV_DIR" ]; then
    export PATH="$PY_VENV_DIR/bin:\$PATH"
fi
EOF_PYENV
        chmod 644 /etc/profile.d/initializer_python.sh || true
    else
        log_info "未检测到 EXTERNALLY-MANAGED，升级系统 pip"
        if ! "${PIP_CMD[@]}" install -U -i https://mirrors.aliyun.com/pypi/simple/ \
            --trusted-host mirrors.aliyun.com \
            --no-input \
            --upgrade pip wheel setuptools
        then
            if "${PIP_CMD[@]}" help install 2>/dev/null | grep -q -- '--break-system-packages'; then
                "${PIP_CMD[@]}" install -U -i https://mirrors.aliyun.com/pypi/simple/ \
                    --trusted-host mirrors.aliyun.com \
                    --no-input \
                    --upgrade pip wheel setuptools \
                    --break-system-packages || log_warning "系统 pip 升级失败"
            else
                log_warning "系统 pip 升级失败"
            fi
        fi
    fi

    log_info "安装 Python 依赖包 (ansible/jmespath/dnspython/docker/jinja2-cli) ..."
    if [ -f "$EXTERNALLY_MANAGED_FILE" ]; then
        # 在受管环境中，只在虚拟环境里安装依赖
        "${PIP_CMD[@]}" install -U -i https://mirrors.aliyun.com/pypi/simple/ \
            --trusted-host mirrors.aliyun.com \
            --no-input \
            ansible jmespath dnspython docker jinja2-cli || log_warning "虚拟环境中部分Python依赖包安装失败"
    else
        if ! "${PIP_CMD[@]}" install -U -i https://mirrors.aliyun.com/pypi/simple/ \
            --trusted-host mirrors.aliyun.com \
            --no-input \
            ansible jmespath dnspython docker jinja2-cli
        then
            if "${PIP_CMD[@]}" help install 2>/dev/null | grep -q -- '--break-system-packages'; then
                "${PIP_CMD[@]}" install -U -i https://mirrors.aliyun.com/pypi/simple/ \
                    --trusted-host mirrors.aliyun.com \
                    --no-input \
                    --break-system-packages \
                    ansible jmespath dnspython docker jinja2-cli || log_warning "系统环境中部分Python依赖包安装失败"
            else
                log_warning "系统环境中部分Python依赖包安装失败"
            fi
        fi
    fi

    log_info "配置 mlocate 忽略目录: /mnt, /tmp"
    UPDATEDB_CONF="/etc/updatedb.conf"
    touch "$UPDATEDB_CONF" && chmod 644 "$UPDATEDB_CONF"
    tmpfile="$(mktemp)"
    awk '
BEGIN {
    found = 0
}
{
    if ($0 ~ /^[[:space:]]*PRUNEPATHS=/ && $0 !~ /^[[:space:]]*#/) {
        found = 1
        paths = ""
        if (match($0, /PRUNEPATHS="[^"]*"/)) {
            paths = substr($0, RSTART + 11, RLENGTH - 12)
        }
        if (paths !~ /(^|[[:space:]])\/mnt([[:space:]]|$)/) {
            paths = paths " /mnt"
        }
        if (paths !~ /(^|[[:space:]])\/tmp([[:space:]]|$)/) {
            paths = paths " /tmp"
        }
        gsub(/[[:space:]]+/, " ", paths)
        sub(/^[[:space:]]+/, "", paths)
        print "PRUNEPATHS=\"" paths "\""
        next
    }
    print
}
END {
    if (found == 0) {
        print "PRUNEPATHS=\"/tmp /mnt\""
    }
}
' "$UPDATEDB_CONF" > "$tmpfile" && mv "$tmpfile" "$UPDATEDB_CONF" || { rm -f "$tmpfile"; log_warning "mlocate 忽略目录配置失败"; }
    updatedb || log_warning "updatedb 执行失败"
    log_success "Python环境配置完成"
}


# 安装yq工具
install_yq() {
    show_step "安装 yq 工具"

    if command -v yq &> /dev/null; then
        log_info "yq 已安装，跳过"
        return 0
    fi

    local yq_path="${TOOLS_DIR}/yq_linux_amd64"
    if [ ! -f "$yq_path" ]; then
        log_warning "yq 二进制文件不存在: $yq_path，跳过安装"
        return 0
    fi

    install -m 0755 "$yq_path" /usr/local/bin/yq || {
        log_warning "yq 安装命令执行失败"
        return 0
    }

    if ! command -v yq &> /dev/null; then
        log_error "yq 安装失败"
    fi

    log_success "yq 安装成功"
}


setup_ssh() {
    show_step "配置 SSH 服务"

    if ! rpm -q openssh-server >/dev/null 2>&1; then
        log_info "安装OpenSSH服务器..."
        pkg_install openssh-server || log_error "OpenSSH服务器安装失败"
    else
        log_info "OpenSSH服务器已安装"
    fi

    SSHD_CONFIG="/etc/ssh/sshd_config"
    if [ ! -f "${SSHD_CONFIG}.bak" ]; then
        cp "$SSHD_CONFIG" "$SSHD_CONFIG.bak"
    fi

    log_info "修改SSH配置..."
    set_sshd_config() {
        local param="$1"
        local value="$2"
        local config_file="$3"

        if grep -q "^[[:space:]]*${param}[[:space:]]*" "$config_file"; then
            sed -i -E "s|^[[:space:]]*${param}[[:space:]]*.*|${param} ${value}|" "$config_file"
        elif grep -q "^[[:space:]]*#[[:space:]]*${param}" "$config_file"; then
            sed -i -E "s|^[[:space:]]*#[[:space:]]*${param}[[:space:]]*.*|${param} ${value}|" "$config_file"
        else
            echo "${param} ${value}" >> "$config_file"
        fi
    }

    set_sshd_config "PermitRootLogin" "yes" "$SSHD_CONFIG"
    set_sshd_config "PasswordAuthentication" "yes" "$SSHD_CONFIG"
    set_sshd_config "PubkeyAuthentication" "yes" "$SSHD_CONFIG"
    set_sshd_config "AuthorizedKeysFile" ".ssh/authorized_keys" "$SSHD_CONFIG"

    log_info "启动SSH服务..."
    systemctl enable sshd >/dev/null 2>&1 || true
    systemctl restart sshd >/dev/null 2>&1 || true

    if systemctl is-active --quiet sshd; then
        log_success "SSH服务启动成功"
    else
        log_error "SSH服务启动失败"
    fi
}


setup_firewall() {
    show_step "配置防火墙"

    if ! command_exists firewall-cmd; then
        log_info "安装 firewalld..."
        pkg_install firewalld || log_warning "firewalld 安装失败"
    fi

    if command_exists firewall-cmd; then
        log_info "启用并启动 firewalld..."
        systemctl enable --now firewalld >/dev/null 2>&1 || true

        log_info "放行 SSH..."
        firewall-cmd --permanent --add-service=ssh >/dev/null 2>&1 || \
            firewall-cmd --permanent --add-port=22/tcp >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        firewall-cmd --list-all || true

        log_success "firewalld 已配置"
    else
        log_warning "firewalld 不可用，跳过防火墙配置"
    fi
}


install_gum() {
    show_step "安装 gum 工具"

    if command_exists gum; then
        log_info "gum 已安装: $(gum --version 2>/dev/null || echo unknown)"
        return 0
    fi

    local gum_rpm="${TOOLS_DIR}/gum-0.17.0-1.x86_64.rpm"
    if [ ! -f "$gum_rpm" ]; then
        log_warning "gum 安装包不存在: $gum_rpm，跳过安装"
        return 0
    fi

    pkg_install "$gum_rpm" || {
        log_warning "gum 安装命令执行失败"
        return 0
    }

    if command_exists gum; then
        log_success "gum 安装成功: $(gum --version 2>/dev/null || echo unknown)"
    else
        log_warning "gum 安装后仍不可用"
    fi
}


main() {
    require_root

    resolve_username "${1:-}"
    configure_user_privileges

    # 优先尝试禁用自动更新，避免后台任务占用包管理器
    disable_automatic_updates

    setup_repositories
    install_basic_packages
    setup_python
    install_yq
    install_gum

    setup_ssh
    setup_firewall

    log_success "初始化完成"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
