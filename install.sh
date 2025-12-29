#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$ROOT_DIR/scripts"

show_step() { printf "\n==> %s\n" "$1"; }
log_info() { printf "[INFO] %s\n" "$1"; }
log_error() { printf "[ERROR] %s\n" "$1"; }

run_init() {
	show_step "运行基础初始化 (scripts/init.sh)"
	local init_script="$SCRIPT_DIR/init.sh"
	if [ ! -x "$init_script" ]; then
		log_error "找不到或不可执行: $init_script"
		exit 1
	fi
	local username="$1"; shift || true
	sudo \
		INIT_USERNAME="$username" \
		ROCKY_REPO_MIRROR="${ROCKY_REPO_MIRROR:-}" \
		SKIP_ROCKY_REPO_MIRROR="${SKIP_ROCKY_REPO_MIRROR:-}" \
		"${init_script}" "$@"
}

run_nodejs() {
	show_step "安装 Node.js 环境 (scripts/nodejs.sh)"
	local node_script="$SCRIPT_DIR/nodejs.sh"
	if [ ! -x "$node_script" ]; then
		log_error "找不到或不可执行: $node_script"
		exit 1
	fi
	"${node_script}"
}

run_cxx() {
	show_step "安装 C/C++ & Qt 开发环境 (scripts/cxx.sh)"
	local cxx_script="$SCRIPT_DIR/cxx.sh"
	if [ ! -x "$cxx_script" ]; then
		log_error "找不到或不可执行: $cxx_script"
		exit 1
	fi
	"${cxx_script}"
}

run_java() {
	show_step "安装 Java 开发环境 (OpenJDK 17) (scripts/java.sh)"
	local java_script="$SCRIPT_DIR/java.sh"
	if [ ! -x "$java_script" ]; then
		log_error "找不到或不可执行: $java_script"
		exit 1
	fi
	"${java_script}"
}

run_golang() {
	show_step "安装 Go 开发环境 (官方分发版) (scripts/golang.sh)"
	local go_script="$SCRIPT_DIR/golang.sh"
	if [ ! -x "$go_script" ]; then
		log_error "找不到或不可执行: $go_script"
		exit 1
	fi
	"${go_script}"
}

run_rust() {
	show_step "安装 Rust 开发环境 (rustup) (scripts/rust.sh)"
	local rust_script="$SCRIPT_DIR/rust.sh"
	if [ ! -f "$rust_script" ]; then
		log_error "找不到脚本: $rust_script"
		exit 1
	fi
	# 直接用 bash 执行，避免可执行位导致失败
	bash "$rust_script" "$@"
}

run_mcp() {
	show_step "安装 MCP 相关依赖 (scripts/mcp.sh)"
	local mcp_script="$SCRIPT_DIR/mcp.sh"
	if [ ! -x "$mcp_script" ]; then
		log_error "找不到或不可执行: $mcp_script"
		exit 1
	fi
	"${mcp_script}"
}

run_docker() {
	show_step "安装 Docker (scripts/docker.sh)"
	local docker_script="$SCRIPT_DIR/docker.sh"
	if [ ! -x "$docker_script" ]; then
		log_error "找不到或不可执行: $docker_script"
		exit 1
	fi
	"${docker_script}"
}

run_codeserver() {
	show_step "安装 code-server (scripts/codeserver.sh)"
	local cs_script="$SCRIPT_DIR/codeserver.sh"
	if [ ! -x "$cs_script" ]; then
		log_error "找不到或不可执行: $cs_script"
		exit 1
	fi
	"${cs_script}"
}

run_claudecode() {
	show_step "安装 Claude Code (scripts/claudecode.sh)"
	local cc_script="$SCRIPT_DIR/claudecode.sh"
	if [ ! -f "$cc_script" ]; then
		log_error "找不到脚本: $cc_script"
		exit 1
	fi
	# 直接用 bash 执行，避免可执行位导致失败
	bash "$cc_script" "$@"
}

run_codex() {
	show_step "安装 Codex (scripts/codex.sh)"
	local codex_script="$SCRIPT_DIR/codex.sh"
	if [ ! -x "$codex_script" ]; then
		log_error "找不到或不可执行: $codex_script"
		exit 1
	fi
	"${codex_script}" "$@"
}

run_gemini() {
	show_step "安装 GeminiCli (scripts/gemini.sh)"
	local gemini_script="$SCRIPT_DIR/gemini.sh"
	if [ ! -f "$gemini_script" ]; then
		log_error "找不到脚本: $gemini_script"
		exit 1
	fi
	# 直接用 bash 执行，避免可执行位导致失败
	bash "$gemini_script" "$@"
}

print_menu() {
	cat <<EOF
可用任务：
  1) 系统基础初始化 (修改 DNF/pip 源，安装基础软件、Python、SSH、firewalld)
	2) 安装 Node.js 环境
	3) 安装 MCP 依赖
	4) 安装 Docker
	5) 安装 code-server
	6) 安装 Claude Code
	7) 安装 Codex
	8) 安装 GeminiCli
    9) 安装 C/C++ & Qt 开发环境
	10) 安装 Java 开发环境 (OpenJDK 17)
	11) 安装 Go 开发环境 (官方分发版)
	12) 安装 Rust 开发环境 (rustup)
  q) 退出
EOF
}

interactive_menu() {
	local username="$1"
	while true; do
		print_menu
		read -rp "请选择任务编号: " choice
		case "$choice" in
			1)
				run_init "$username"
				;;
			2)
				run_nodejs
				;;
			9)
				run_cxx
				;;
			10)
				run_java
				;;
			11)
				run_golang
				;;
			12)
				run_rust
				;;
			3)
				run_mcp
				;;
			4)
				run_docker
				;;
			5)
				run_codeserver
				;;
			6)
				run_claudecode
				;;
			7)
				run_codex
				;;
			8)
				run_gemini
				;;
			q|Q)
				log_info "已退出"
				exit 0
				;;
			*)
				log_error "无效选择: $choice"
				;;
		esac
	done
}

usage() {
	cat <<EOF
用法: $0 [任务]

任务 (可选)：
  init        运行系统基础初始化 (调用 scripts/init.sh)
	nodejs      安装 Node.js 环境 (调用 scripts/nodejs.sh)
	cxx         安装 C/C++ & Qt 开发环境 (调用 scripts/cxx.sh)
	java        安装 Java 开发环境 (OpenJDK 17) (调用 scripts/java.sh)
	golang      安装 Go 开发环境 (官方分发版) (调用 scripts/golang.sh)
	rust        安装 Rust 开发环境 (rustup) (调用 scripts/rust.sh)
	mcp         安装 MCP 依赖 (调用 scripts/mcp.sh)
	docker      安装 Docker (调用 scripts/docker.sh)
	codeserver  安装 code-server (调用 scripts/codeserver.sh)
	claudecode  安装 Claude Code (可选: --api-key <key> 或设置 CLAUDECODE_API_KEY)
	codex       安装 Codex (可选: --api-key <key> 或设置 OPENAI_API_KEY)
	gemini      安装 GeminiCli (可选: --api-key <key> 或设置 GEMINI_API_KEY)
  help        显示本帮助

不带参数运行时，将进入交互式菜单。
EOF
}

main() {
	if [ "$(id -u)" -eq 0 ]; then
		log_error "请使用非 root 用户运行此脚本"
		exit 1
	fi

	local current_user
	current_user="$(id -un)"

	local cmd="${1:-}"
	case "${cmd:-}" in
		init)
			shift || true
			run_init "$current_user" "$@"
			;;
		nodejs)
			shift || true
			run_nodejs
			;;
		cxx)
			shift || true
			run_cxx
			;;
		java)
			shift || true
			run_java
			;;
		golang)
			shift || true
			run_golang
			;;
		rust)
			shift || true
			run_rust "$@"
			;;
		mcp)
			shift || true
			run_mcp
			;;
		docker)
			shift || true
			run_docker
			;;
		codeserver)
			shift || true
			run_codeserver
			;;
		claudecode)
			shift || true
			run_claudecode "$@"
			;;
		codex)
			shift || true
			run_codex "$@"
			;;
		gemini)
			shift || true
			run_gemini "$@"
			;;
		help|-h|--help)
			usage
			;;
		"")
			interactive_menu "$current_user"
			;;
		*)
			log_error "未知任务: $cmd"
			usage
			exit 1
			;;
	esac
}

main "$@"
