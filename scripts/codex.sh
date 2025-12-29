p#!/usr/bin/env bash
set -euo pipefail

# Simple logging helpers
_now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
show_step() { printf "\n==> %s\n" "$1"; }
log_info() { printf "%s [INFO] %s\n" "$(_now)" "$1"; }
log_warning() { printf "%s [WARN] %s\n" "$(_now)" "$1"; }
log_error() { printf "%s [ERROR] %s\n" "$(_now)" "$1"; }
log_success() { printf "%s [OK] %s\n" "$(_now)" "$1"; }

die() { log_error "$1"; exit 1; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

OPENAI_BASE_URL_DEFAULT="https://api.aicodemirror.com/api/codex/backend-api/codex"

sanitize_api_key() {
    # Remove newlines/control chars commonly introduced by copy-paste.
    local key="$1"
    key="${key//$'\r'/}"
    key="${key//$'\n'/}"
    # Trim surrounding whitespace.
    key="$(printf '%s' "$key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

    # Reject remaining control characters (safety).
    if printf '%s' "$key" | LC_ALL=C grep -q '[[:cntrl:]]'; then
        die "OPENAI_API_KEY 包含控制字符，请重新复制后再输入（不要包含换行/空字符）"
    fi

    printf '%s' "$key"
}

ensure_npm_global_prefix_writable() {
    # If npm global prefix isn't writable, switch to user prefix ~/.npm-global.
    local prefix
    prefix="$(npm prefix -g 2>/dev/null || true)"
    if [ -z "${prefix}" ]; then
        log_warning "无法获取 npm 全局 prefix，跳过 prefix 检查"
        return 0
    fi

    if [ -w "${prefix}" ]; then
        return 0
    fi

    show_step "配置 npm 全局安装目录 (用户级)"
    log_info "当前 npm prefix 不可写: ${prefix}"
    log_info "将 npm prefix 切换为: $HOME/.npm-global"

    mkdir -p "$HOME/.npm-global" "$HOME/.npm-global/bin"
    npm config set prefix "$HOME/.npm-global" --location=user >/dev/null 2>&1 || \
        npm config set prefix "$HOME/.npm-global" >/dev/null 2>&1 || true

    # Ensure PATH contains ~/.npm-global/bin on future shells
    local bashrc="$HOME/.bashrc"
    touch "$bashrc"
    if ! grep -q "\.npm-global/bin" "$bashrc" 2>/dev/null; then
        cat >>"$bashrc" <<'EOF_PATH'
# npm global bin (managed by initializer)
export PATH="$HOME/.npm-global/bin:$PATH"
EOF_PATH
        log_info "已写入 ~/.bashrc: ~/.npm-global/bin"
    fi

    # Apply in current session
    export PATH="$HOME/.npm-global/bin:$PATH"
}

install_codex() {
    show_step "安装 Codex (@openai/codex)"

    if command_exists codex; then
        log_info "检测到已安装 codex: $(codex -V 2>/dev/null || echo unknown)"
        log_info "将继续尝试更新到最新版本"
    fi

    if command_exists npm; then
        ensure_npm_global_prefix_writable
        npm install -g @openai/codex
        return 0
    fi

    if command_exists brew; then
        log_info "未检测到 npm，尝试使用 brew 安装 codex"
        brew install codex
        return 0
    fi

    die "未检测到 npm 或 brew，无法安装 codex。建议先运行: ./install.sh nodejs"
}

print_help() {
    cat <<'EOF'
用法: scripts/codex.sh [--api-key <key>]

说明：
- 安装官方原版包: npm install -g @openai/codex
- 创建 ~/.codex，并写入 auth.json 与 config.toml
- 最后运行 codex -V 验证

参数：
  --api-key <key>   用于写入 ~/.codex/auth.json（也可使用环境变量 OPENAI_API_KEY）
  -h, --help        显示本帮助
EOF
}

get_api_key() {
    local api_key="${1:-}"
    # Trim whitespace
    api_key="$(printf '%s' "$api_key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [ -n "${api_key}" ]; then
        sanitize_api_key "${api_key}"
        return 0
    fi

    api_key="${OPENAI_API_KEY:-}"
    # Trim whitespace
    api_key="$(printf '%s' "$api_key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [ -n "${api_key}" ]; then
        sanitize_api_key "${api_key}"
        return 0
    fi

    if [ -t 0 ]; then
        read -rp "请输入 OPENAI_API_KEY (将写入 ~/.codex/auth.json): " api_key
        # Trim whitespace
        api_key="$(printf '%s' "$api_key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        echo
    fi

    if [ -z "${api_key}" ]; then
        die "未提供 OPENAI_API_KEY。请设置环境变量 OPENAI_API_KEY 或传参 --api-key。"
    fi

    sanitize_api_key "${api_key}"
}

write_codex_config() {
    show_step "写入 Codex 配置 (~/.codex)"

    local api_key
    api_key="${1:-}"
    if [ -z "${api_key}" ]; then
        die "未提供 OPENAI_API_KEY。"
    fi

    local codex_dir="$HOME/.codex"

    # 按需求：rm -rf ~/.codex && mkdir ~/.codex
    rm -rf "${codex_dir}"
    mkdir -p "${codex_dir}"

    # auth.json
    rm -f "${codex_dir}/auth.json"
    if command_exists jq; then
        jq -n --arg key "${api_key}" '{OPENAI_API_KEY: $key}' >"${codex_dir}/auth.json"
    else
        # Fallback: minimal JSON escaping.
        local escaped_key
        escaped_key="${api_key//\\/\\\\}"
        escaped_key="${escaped_key//\"/\\\"}"
        printf '{\n  "OPENAI_API_KEY": "%s"\n}\n' "${escaped_key}" >"${codex_dir}/auth.json"
    fi

    # config.toml (按需求：原封不动粘贴内容)
    rm -f "${codex_dir}/config.toml"
    cat >"${codex_dir}/config.toml" <<'EOF'
model_provider = "aicodemirror"
model = "gpt-5.2"
model_reasoning_effort = "high"
disable_response_storage = true
preferred_auth_method = "apikey"

[model_providers.aicodemirror]
name = "aicodemirror"
base_url = "https://api.aicodemirror.com/api/codex/backend-api/codex"
wire_api = "responses"
EOF

    chmod 700 "${codex_dir}" || true
    chmod 600 "${codex_dir}/auth.json" "${codex_dir}/config.toml" || true

    log_success "已生成: ${codex_dir}/auth.json, ${codex_dir}/config.toml"
}

write_openai_env_to_bashrc() {
    show_step "写入 OpenAI 环境变量到 ~/.bashrc"

    local api_key
    api_key="${1:-}"
    if [ -z "${api_key}" ]; then
        die "未提供 OPENAI_API_KEY。"
    fi

	# Defensive: ensure no newlines/control chars can break ~/.bashrc
	api_key="$(sanitize_api_key "${api_key}")"

    local bashrc="$HOME/.bashrc"
    local begin_marker="# OPENAI Environment Variables (managed by initializer) - begin"
    local end_marker="# OPENAI Environment Variables (managed by initializer) - end"

    touch "$bashrc"

    local tmpfile
    tmpfile="$(mktemp)"
    awk -v begin="$begin_marker" -v end="$end_marker" '
        $0 == begin { skipping = 1; next }
        skipping && $0 == end { skipping = 0; next }
        !skipping { print }
    ' "$bashrc" >"$tmpfile" && mv "$tmpfile" "$bashrc" || rm -f "$tmpfile"

    {
        printf '%s\n' "${begin_marker}"
		printf 'export OPENAI_BASE_URL=%q\n' "${OPENAI_BASE_URL_DEFAULT}"
		printf 'export OPENAI_API_KEY=%q\n' "${api_key}"
        printf '%s\n' "${end_marker}"
    } >>"$bashrc"

    log_success "已写入 ~/.bashrc（新终端会生效）"
}

verify_codex() {
    show_step "验证 Codex 安装"
    if ! command_exists codex; then
        die "未找到 codex 命令。请确认 npm 全局 bin 在 PATH 中，或重启终端后再试。"
    fi

    codex -V
    log_success "Codex 可用。建议重启终端以确保 PATH 生效。"
}

configure_codex_mcp_servers() {
    show_step "配置 Codex MCP Servers"

    if ! command_exists codex; then
        log_warning "未找到 codex 命令，跳过 MCP 配置"
        return 0
    fi

    if ! command_exists npx; then
        log_warning "未找到 npx 命令（通常随 npm 一起安装），跳过基于 npx 的 MCP Server 配置"
    fi

    # mcp-server-fetch MCP 服务器（依赖 uvx）
    if command_exists uvx; then
        codex mcp add fetch -- uvx mcp-server-fetch || true
    else
        log_warning "未找到 uvx，跳过 mcp-server-fetch（可先运行: ./install.sh mcp）"
    fi

    # Context7 MCP 服务器
    if command_exists npx; then
        codex mcp add context7 -- npx -y @upstash/context7-mcp || true
        codex mcp add sequential-thinking -- npx -y @modelcontextprotocol/server-sequential-thinking || true
        codex mcp add puppeteer -- npx -y @modelcontextprotocol/server-puppeteer || true
        codex mcp add playwright -- npx -y @playwright/mcp@latest || true
        codex mcp add chrome-devtools -- npx -y chrome-devtools-mcp@latest || true
    fi

    log_success "MCP Servers 配置步骤已执行（如已存在将被忽略）"
}

main() {
    local api_key="${OPENAI_API_KEY:-}"
    local show_help=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --api-key)
                shift || true
                api_key="${1:-}"
                ;;
            -h|--help)
                show_help=true
                ;;
            *)
                ;;
        esac
        shift || true
    done

    if [ "${show_help}" = true ]; then
        print_help
        exit 0
    fi

    install_codex

	local resolved_api_key
	resolved_api_key="$(get_api_key "${api_key}")"
	write_codex_config "${resolved_api_key}"
	write_openai_env_to_bashrc "${resolved_api_key}"
    verify_codex
    configure_codex_mcp_servers

    show_step "开始使用"
    log_info "在项目目录运行: codex"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
