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
    require_sudo
    ensure_pkg_manager
    sudo_cmd "${PKG_MANAGER}" -y makecache >/dev/null 2>&1 || log_warning "${PKG_MANAGER} makecache 可能失败"
}

pkg_install() {
    require_sudo
    ensure_pkg_manager
    sudo_cmd "${PKG_MANAGER}" -y install "$@" || return 1
}

ver_ge() {
    # returns 0 if $1 >= $2 (version compare)
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

resolve_java_home_17() {
    local java_home_path=""

    if [ -d "/usr/lib/jvm/java-17-openjdk" ]; then
        java_home_path="/usr/lib/jvm/java-17-openjdk"
    elif [ -d "/usr/lib/jvm/java-17-openjdk-amd64" ]; then
        java_home_path="/usr/lib/jvm/java-17-openjdk-amd64"
    else
        java_home_path="$(find /usr/lib/jvm -maxdepth 1 -type d \( -name '*java-17*' -o -name '*java-1.17*' \) 2>/dev/null | head -n1 || true)"
    fi

    if [ -z "$java_home_path" ] || [ ! -d "$java_home_path" ]; then
        return 1
    fi

    printf '%s' "$java_home_path"
}

install_openjdk17() {
    show_step "安装 Java 开发环境 (OpenJDK 17)"

    pkg_makecache

    log_info "安装 OpenJDK 17..."
    pkg_install java-17-openjdk-devel || log_error "OpenJDK 17 安装失败"

    local java_home
    log_info "检测 JAVA_HOME 路径..."
    if ! java_home="$(resolve_java_home_17)"; then
        log_error "无法找到 Java 17 安装路径"
    fi

    log_info "Java 17 安装路径: $java_home"

    # 配置 alternatives 使用 Java 17
    if [ -x "$java_home/bin/java" ]; then
        local current_java_version
        current_java_version="$(java -version 2>&1 | grep -Eo '"[0-9]+' | tr -d '"' | head -n1 2>/dev/null || echo '0')"
        if [ "$current_java_version" != "17" ]; then
            local alt_cmd=""
            if command_exists update-alternatives; then
                alt_cmd="update-alternatives"
            elif command_exists alternatives; then
                alt_cmd="alternatives"
            fi

            if [ -n "$alt_cmd" ]; then
                log_info "设置 ${alt_cmd} 使用 Java 17..."
                sudo_cmd "$alt_cmd" --install /usr/bin/java java "$java_home/bin/java" 1 || true
                sudo_cmd "$alt_cmd" --set java "$java_home/bin/java" || true
                sudo_cmd "$alt_cmd" --install /usr/bin/javac javac "$java_home/bin/javac" 1 || true
                sudo_cmd "$alt_cmd" --set javac "$java_home/bin/javac" || true
            else
                log_warning "未找到 alternatives/update-alternatives，跳过默认 Java 切换"
            fi
        fi
    fi

    # 写入 /etc/profile.d/java.sh
    local profiled_java="/etc/profile.d/java.sh"
    log_info "写入 Java 环境变量到 ${profiled_java} ..."
    sudo_cmd tee "$profiled_java" >/dev/null <<EOF_JAVA_ENV
# Java environment (managed by initializer)
export JAVA_HOME="$java_home"
export PATH="\$JAVA_HOME/bin:\$PATH"
EOF_JAVA_ENV
    sudo_cmd chmod 644 "$profiled_java" || true

    # 立刻生效当前会话
    export JAVA_HOME="$java_home"
    export PATH="$JAVA_HOME/bin:$PATH"

    log_success "OpenJDK 17 安装与环境变量配置完成"
}

install_maven() {
    show_step "安装 Maven"

    pkg_makecache
    pkg_install maven || log_warning "Maven 安装失败"

    log_info "配置 Maven 阿里云镜像..."
    mkdir -p "$HOME/.m2"
    cat > "$HOME/.m2/settings.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0
          http://maven.apache.org/xsd/settings-1.0.0.xsd">
  <mirrors>
    <mirror>
      <id>aliyunmaven</id>
      <mirrorOf>*</mirrorOf>
      <name>阿里云公共仓库</name>
      <url>https://maven.aliyun.com/repository/public</url>
    </mirror>
  </mirrors>
</settings>
EOF

    log_success "Maven 配置完成"
}

install_gradle() {
    show_step "检查并安装 Gradle"

    local required_ver="8.9"
    local installed_ver=""

    if command -v gradle >/dev/null 2>&1; then
        installed_ver="$(gradle -v 2>/dev/null | awk '/Gradle /{print $2; exit}')"
    fi

    if [ -n "$installed_ver" ] && ver_ge "$installed_ver" "$required_ver"; then
        log_info "Gradle 已安装且版本满足要求: $installed_ver (>= $required_ver)，跳过安装"
    else
        pkg_makecache
        pkg_install unzip || log_warning "unzip 安装失败"

        local target_ver="$required_ver"
        local zip_file="gradle-${target_ver}-bin.zip"
        local url_primary="https://mirrors.cloud.tencent.com/gradle/${zip_file}"
        local url_fallback="https://services.gradle.org/distributions/${zip_file}"

        log_info "安装 Gradle ${target_ver}..."

        pushd /tmp >/dev/null
        rm -f "$zip_file"

        local download_ok=false
        if command -v wget >/dev/null 2>&1; then
            wget -q "$url_primary" -O "$zip_file" || wget -q "$url_fallback" -O "$zip_file" || true
            [ -s "$zip_file" ] && download_ok=true
        elif command -v curl >/dev/null 2>&1; then
            curl -fsSL "$url_primary" -o "$zip_file" || curl -fsSL "$url_fallback" -o "$zip_file" || true
            [ -s "$zip_file" ] && download_ok=true
        else
            log_warning "未找到 wget/curl，无法下载 Gradle，跳过安装"
            popd >/dev/null
            return 0
        fi

        if [ "$download_ok" != true ]; then
            log_warning "Gradle 下载失败，跳过安装"
            popd >/dev/null
            return 0
        fi

        sudo_cmd unzip -q -d /opt "$zip_file" || {
            log_warning "Gradle 解压失败，跳过安装"
            rm -f "$zip_file"
            popd >/dev/null
            return 0
        }

        sudo_cmd ln -sf "/opt/gradle-${target_ver}/bin/gradle" /usr/local/bin/gradle || true
        rm -f "$zip_file"
        popd >/dev/null

        if command -v gradle >/dev/null 2>&1; then
            local new_ver
            new_ver="$(gradle -v 2>/dev/null | awk '/Gradle /{print $2; exit}')"
            if [ -n "$new_ver" ] && ver_ge "$new_ver" "$required_ver"; then
                log_success "Gradle 安装成功: $new_ver"
            else
                log_warning "Gradle 安装后版本校验未通过（检测到: ${new_ver:-未知}）"
            fi
        else
            log_warning "Gradle 安装后不可用"
        fi
    fi

    log_info "配置 Gradle 阿里云镜像..."
    mkdir -p "$HOME/.gradle"
    cat > "$HOME/.gradle/init.gradle" <<'EOF'
allprojects {
    repositories {
        maven { url 'https://maven.aliyun.com/repository/public/' }
        maven { url 'https://maven.aliyun.com/repository/spring/' }
        maven { url 'https://maven.aliyun.com/repository/google/' }
        maven { url 'https://maven.aliyun.com/repository/gradle-plugin/' }
        maven { url 'https://maven.aliyun.com/repository/spring-plugin/' }
        mavenCentral()
        gradlePluginPortal()
    }
}
EOF

    log_success "Gradle 配置完成"
}

print_versions() {
    show_step "Java/Maven/Gradle 版本信息"

    command -v java >/dev/null 2>&1 && java -version || log_warning "Java 未正确安装"
    command -v mvn >/dev/null 2>&1 && mvn -version || log_warning "Maven 未正确安装"
    command -v gradle >/dev/null 2>&1 && gradle -version || log_warning "Gradle 未正确安装"
}

main() {
    if [ "$(id -u)" -eq 0 ]; then
        log_warning "建议使用非 root 用户运行（脚本会用 sudo 安装系统依赖）"
    fi

    install_openjdk17
    install_maven
    install_gradle
    print_versions

    log_success "Java 开发环境安装完成"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
