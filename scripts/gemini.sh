#!/usr/bin/env bash
set -euo pipefail

# Simple logging helpers
_now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
show_step() { printf "\n==> %s\n" "$1"; }
log_info() { printf "%s [INFO] %s\n" "$(_now)" "$1"; }
log_warning() { printf "%s [WARN] %s\n" "$(_now)" "$1"; }
log_error() { printf "%s [ERROR] %s\n" "$(_now)" "$1"; }
log_success() { printf "%s [OK] %s\n" "$(_now)" "$1"; }

DEFAULT_GEMINI_BASE_URL="https://api.aicodemirror.com/api/gemini"

usage() {
	cat <<'EOF'
用法: scripts/gemini.sh [--api-key <key>] [--base-url <url>]

功能：
  - 安装 GeminiCli 官方原版包: npm install -g @google/gemini-cli
  - 将 GEMINI 环境变量写入 shell 配置文件 (~/.bashrc, ~/.zshrc)

参数：
  --api-key   写入 GEMINI_API_KEY（也可通过环境变量 GEMINI_API_KEY 提供）
  --base-url  写入 GOOGLE_GEMINI_BASE_URL（默认 https://api.aicodemirror.com/api/gemini）
EOF
}

is_tty() {
	[ -t 0 ] && [ -t 1 ]
}

prompt_for_api_key_if_needed() {
	# If API key wasn't provided via args/env, ask interactively when possible.
	if [ -n "${GEMINI_API_KEY_TO_WRITE:-}" ]; then
		return 0
	fi
	if ! is_tty; then
		return 0
	fi

	show_step "配置 GEMINI_API_KEY"
	printf "请输入 GEMINI_API_KEY (回车跳过): "
	# shellcheck disable=SC2162
	read -r GEMINI_API_KEY_TO_WRITE
	echo
	# allow skip
	return 0
}

parse_args() {
	GEMINI_API_KEY_TO_WRITE="${GEMINI_API_KEY:-}"
	GOOGLE_GEMINI_BASE_URL_TO_WRITE="${GOOGLE_GEMINI_BASE_URL:-$DEFAULT_GEMINI_BASE_URL}"

	while [ $# -gt 0 ]; do
		case "$1" in
			--api-key)
				shift
				GEMINI_API_KEY_TO_WRITE="${1:-}"
				;;
			--base-url)
				shift
				GOOGLE_GEMINI_BASE_URL_TO_WRITE="${1:-}"
				;;
			-h|--help)
				usage
				exit 0
				;;
			*)
				log_error "未知参数: $1"
				usage
				exit 1
				;;
		esac
		shift || true
	done

	if [ -z "${GOOGLE_GEMINI_BASE_URL_TO_WRITE:-}" ]; then
		GOOGLE_GEMINI_BASE_URL_TO_WRITE="$DEFAULT_GEMINI_BASE_URL"
	fi
}

require_node() {
	if ! command -v npm >/dev/null 2>&1; then
		log_error "未检测到 npm。请先运行: ./install.sh nodejs"
		exit 1
	fi
}

install_gemini_cli() {
	show_step "安装 GeminiCli (@google/gemini-cli)"

	# 按官方命令安装；如需自定义 registry，可通过 NPM_CONFIG_REGISTRY 环境变量控制。
	npm install -g @google/gemini-cli || {
		log_error "npm 安装 @google/gemini-cli 失败"
		exit 1
	}

	if command -v gemini >/dev/null 2>&1; then
		log_success "GeminiCli 已安装: $(command -v gemini)"
	else
		log_warning "已执行安装，但未在 PATH 中找到 gemini。请确认 npm global bin 在 PATH 中。"
	fi
}

configure_gemini_mcp_servers() {
	show_step "配置 Gemini MCP Servers"

	if ! command -v gemini >/dev/null 2>&1; then
		log_warning "未找到 gemini 命令，跳过 MCP 配置"
		return 0
	fi

	if ! command -v npx >/dev/null 2>&1; then
		log_warning "未找到 npx 命令（通常随 npm 一起安装），跳过基于 npx 的 MCP Server 配置"
	fi

	# mcp-server-fetch MCP 服务器（依赖 uvx）
	if command -v uvx >/dev/null 2>&1; then
		gemini mcp add fetch uvx mcp-server-fetch || true
	else
		log_warning "未找到 uvx，跳过 mcp-server-fetch（可先运行: ./install.sh mcp）"
	fi

	# npx 系列 MCP 服务器
	if command -v npx >/dev/null 2>&1; then
		gemini mcp add context7 npx -y @upstash/context7-mcp || true
		gemini mcp add sequential-thinking npx -y @modelcontextprotocol/server-sequential-thinking || true
		gemini mcp add puppeteer npx -y @modelcontextprotocol/server-puppeteer || true
		gemini mcp add playwright npx -y @playwright/mcp@latest || true
		gemini mcp add chrome-devtools npx -y chrome-devtools-mcp@latest || true
	fi

	log_success "MCP Servers 配置步骤已执行（如已存在将被忽略）"
}

write_env_block() {
	local profile_file="$1"
	local begin_marker="# GEMINI Environment Variables (managed by initializer) - begin"
	local end_marker="# GEMINI Environment Variables (managed by initializer) - end"

	touch "$profile_file"

	# 删除旧的 managed block（如果存在）
	local tmpfile
	tmpfile="$(mktemp)"
	awk -v begin="$begin_marker" -v end="$end_marker" '
		$0 == begin { skipping = 1; next }
		skipping && $0 == end { skipping = 0; next }
		!skipping { print }
	' "$profile_file" >"$tmpfile" && mv "$tmpfile" "$profile_file" || rm -f "$tmpfile"

	{
		echo "${begin_marker}"
		echo "export GOOGLE_GEMINI_BASE_URL=\"${GOOGLE_GEMINI_BASE_URL_TO_WRITE}\""
		if [ -n "${GEMINI_API_KEY_TO_WRITE:-}" ]; then
			echo "export GEMINI_API_KEY=\"${GEMINI_API_KEY_TO_WRITE}\""
		else
			echo "export GEMINI_API_KEY=\"\"  # TODO: set your API key"
		fi
		echo "${end_marker}"
	} >>"$profile_file"
}

configure_shell_env() {
	show_step "写入 GEMINI 环境变量到 shell 配置"

	local wrote_any=false

	# bash: 总是写入 ~/.bashrc
	write_env_block "$HOME/.bashrc"
	wrote_any=true

	# zsh: 如果存在则写入
	if [ -f "$HOME/.zshrc" ]; then
		write_env_block "$HOME/.zshrc"
	fi

	if [ "${wrote_any}" = true ]; then
		log_success "环境变量已写入。新终端会自动生效。"
	fi
}

print_next_steps() {
	show_step "后续操作 (手动)"
	cat <<'EOF'
1) 重启终端，或手动执行: source ~/.bashrc
2) 启动 GeminiCli: gemini
3) 在登录页选择: Use Gemini API Key
4) 在 Gemini 内开启 Preview Features:
   - 输入: /settings
   - 将 Preview Features 切换为 true
5) 退出并重启 gemini 后切换模型:
   - 输入: /quit
   - 再次运行: gemini
   - 输入: /model
   - 选择 Gemini 3 Pro
EOF

	if [ -z "${GEMINI_API_KEY_TO_WRITE:-}" ]; then
		log_warning "未写入 GEMINI_API_KEY。请在 ~/.bashrc 中设置，或重跑: scripts/gemini.sh --api-key <key>"
	fi
}

main() {
	parse_args "$@"
	prompt_for_api_key_if_needed
	require_node
	install_gemini_cli
	configure_shell_env
	configure_gemini_mcp_servers
	print_next_steps
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	main "$@"
fi
