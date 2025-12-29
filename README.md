# Rocky Linux 9 开发环境快速初始化工具集

一键配置 Rocky Linux 9 开发环境的自动化脚本集合，支持系统初始化、开发工具安装、AI 编程助手部署等功能。

## 功能特性

- **系统初始化**: 可选切换 Rocky Linux 软件源镜像、配置 pip 镜像，安装基础软件、Python、SSH、firewalld 防火墙
- **Node.js 环境**: 快速安装 Node.js LTS 版本及 npm/yarn
- **MCP 依赖**: 安装 Model Context Protocol 相关工具（uvx、pipx 等）
- **Docker**: 一键安装 Docker（优先使用系统仓库，必要时自动添加 Docker CE 官方仓库）并配置 daemon.json
- **code-server**: 部署基于浏览器的 VS Code 服务器
- **C/C++ & Qt**: 安装 C++ 工具链、Qt5 开发包与常见 C++ 包管理工具
- **AI 编程助手**:
  - Claude Code (Anthropic)
  - Codex (OpenAI)
  - Gemini CLI (Google)

## 快速开始

### 交互式菜单

不带参数运行，进入交互式菜单选择任务：

```bash
./install.sh
```

### 命令行模式

直接指定任务名称：

```bash
# 系统初始化
./install.sh init

# 安装 Node.js
./install.sh nodejs

# 安装 C/C++ & Qt 开发环境
./install.sh cxx

# 安装 Docker
./install.sh docker

# 安装 code-server
./install.sh codeserver

# 安装 AI 编程助手
./install.sh claudecode --api-key "YOUR_API_KEY"
./install.sh codex --api-key "YOUR_API_KEY"
./install.sh gemini --api-key "YOUR_API_KEY"
```

## 详细说明

### 1. 系统初始化 (`init`)

**功能**：
- 可选切换 Rocky Linux 软件源镜像（默认阿里云，可通过 `ROCKY_REPO_MIRROR` 自定义，或 `SKIP_ROCKY_REPO_MIRROR=1` 跳过）
- 配置 pip 镜像（`/etc/pip.conf` + 用户级 `~/.pip/pip.conf`）
- 安装基础软件包（git, curl, wget, gcc/g++/make 等常见构建依赖）
- 安装 Python 3 及开发工具
- 配置 SSH 服务
- 配置 firewalld 防火墙（放行 SSH）
- 设置用户 sudo 免密

**使用**：
```bash
./install.sh init
```

### 2. Node.js 环境 (`nodejs`)

使用仓库内置离线包安装 Node.js（`assets/node-*.tar.xz`），并写入 `~/.bashrc`。

```bash
./install.sh nodejs
node -v  # 验证安装
```

### 3. MCP 依赖 (`mcp`)

安装 Model Context Protocol 工具链：
- uvx (Python 包执行器)
- pipx (Python 应用隔离安装)
- MCP 相关 Python 包

```bash
./install.sh mcp
```

### 4. Docker (`docker`)

安装 Docker 并配置 `insecure-registries` 等 daemon 选项（是否提供 `docker compose` 取决于系统仓库包）。

```bash
./install.sh docker
docker --version  # 验证安装
```

### 5. code-server (`codeserver`)

安装基于浏览器的 VS Code 服务器。

```bash
./install.sh codeserver
```

### 6. C/C++ & Qt (`cxx`)

安装 C/C++ 开发工具链与 Qt5 常用开发包，并安装常见 C++ 依赖管理工具：

- C/C++：`gcc`/`gcc-c++`、`cmake`/`ninja-build`、`pkgconf-pkg-config` 等常见构建依赖（以脚本实际安装列表为准）
- Qt5：`qt5-qtbase-devel`、`qt5-qttools-devel`、`qt5-qtdeclarative-devel`、`qt5-qtwebsockets-devel` 等（按仓库实际可用包为准）
- xmake：使用仓库内置安装包 `assets/tools/xmake-v3.0.0.gz.run`
- vcpkg：安装到 `~/.vcpkg`，并写入 `~/.bashrc` 的 `VCPKG_ROOT`/`PATH`
- conan：通过 pipx 安装（推荐方式，避免污染系统 Python 环境）

```bash
./install.sh cxx
```

**配置 HTTPS**：

1. 生成自签名证书：
```bash
sudo mkdir -p /etc/code-server/ssl && sudo chmod 700 /etc/code-server/ssl
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/code-server/ssl/code-server.key \
  -out /etc/code-server/ssl/code-server.crt \
  -subj "/CN=your.domain.com"
sudo chmod 600 /etc/code-server/ssl/code-server.key
```

2. 修改配置文件 `~/.config/code-server/config.yaml`：
```yaml
bind-addr: 0.0.0.0:8080
auth: password
password: "your-strong-password"
cert: /etc/code-server/ssl/code-server.crt
cert-key: /etc/code-server/ssl/code-server.key
```

3. 重启服务：
```bash
sudo systemctl restart code-server@$(whoami)
```

详细配置说明见文档末尾 [code-server HTTPS 配置](#code-server-https-配置详解)。

### 6. AI 编程助手

#### Claude Code (Anthropic)

```bash
# 交互式安装
./install.sh claudecode

# 非交互安装（推荐 CI/自动化）
CLAUDECODE_API_KEY="sk-ant-xxx" ./install.sh claudecode

# 显式传参
./install.sh claudecode --api-key "sk-ant-xxx"

# 验证
claude -v
```

#### Codex (OpenAI)

```bash
# 交互式安装
./install.sh codex

# 非交互安装
OPENAI_API_KEY="sk-xxx" ./install.sh codex

# 验证
codex -v
```

#### Gemini CLI (Google)

```bash
# 交互式安装
./install.sh gemini

# 非交互安装
GEMINI_API_KEY="your-key" ./install.sh gemini

# 自定义 API 地址
./install.sh gemini --api-key "your-key" --base-url "https://api.gemini.com"

# 验证
gemini -v
```

## 环境变量配置

AI 工具的 API Key 会自动写入 shell 配置文件（`~/.bashrc` 或 `~/.zshrc`）：

```bash
# Claude Code
export ANTHROPIC_API_KEY="sk-ant-xxx"

# Codex
export OPENAI_API_KEY="sk-xxx"
export OPENAI_BASE_URL="https://api.openai.com"

# Gemini
export GEMINI_API_KEY="your-key"
export GOOGLE_GEMINI_BASE_URL="https://api.gemini.com"
```

使配置生效：
```bash
source ~/.bashrc  # 或 source ~/.zshrc
```

## 目录结构

```
rocky9-init/
├── install.sh              # 主安装脚本（交互式菜单）
├── scripts/
│   ├── init.sh            # 系统初始化
│   ├── nodejs.sh          # Node.js 安装
│   ├── mcp.sh             # MCP 依赖安装
│   ├── docker.sh          # Docker 安装
│   ├── codeserver.sh      # code-server 安装
│   ├── cxx.sh             # C/C++ & Qt 开发环境安装
│   ├── java.sh            # Java 开发环境安装
│   ├── golang.sh          # Go 开发环境安装
│   ├── rust.sh            # Rust 开发环境安装
│   ├── claudecode.sh      # Claude Code 安装
│   ├── codex.sh           # Codex 安装
│   └── gemini.sh          # Gemini CLI 安装
├── assets/                 # 资源文件
├── kvm/                    # KVM 相关配置（可选）
└── README.md
```

## 常见问题

### 权限问题

所有脚本需以普通用户（非 root）运行：

```bash
./install.sh    # 正确
sudo ./install.sh  # 错误！
```

### API Key 管理

建议使用环境变量或命令行传参，避免在脚本中硬编码：

```bash
# 推荐
export ANTHROPIC_API_KEY="sk-ant-xxx"
./install.sh claudecode

# 或
./install.sh claudecode --api-key "sk-ant-xxx"
```

### 镜像源配置

`init.sh` 默认使用阿里云镜像；可通过 `ROCKY_REPO_MIRROR` 自定义 Rocky Linux 软件源镜像，或设置 `SKIP_ROCKY_REPO_MIRROR=1` 跳过软件源修改；pip 镜像可编辑 `/etc/pip.conf`。

## code-server HTTPS 配置详解

完整的 code-server HTTPS 配置说明：

### 关键路径
- 配置文件：`~/.config/code-server/config.yaml`
- 服务管理：`sudo systemctl restart code-server@<username>`
- 证书位置：建议 `/etc/code-server/ssl/`（权限 700）

### 使用自签名证书

1. 创建证书目录：
```bash
sudo mkdir -p /etc/code-server/ssl && sudo chmod 700 /etc/code-server/ssl
```

2. 生成证书（替换 `your.domain.com`）：
```bash
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/code-server/ssl/code-server.key \
  -out /etc/code-server/ssl/code-server.crt \
  -subj "/CN=your.domain.com"
sudo chmod 600 /etc/code-server/ssl/code-server.key
```

3. 在浏览器中访问 `https://your.domain.com:8080`，接受自签名证书警告。

### 使用受信任证书（Let's Encrypt）

```bash
sudo cp /path/to/fullchain.pem /etc/code-server/ssl/code-server.crt
sudo cp /path/to/privkey.pem /etc/code-server/ssl/code-server.key
sudo chmod 600 /etc/code-server/ssl/code-server.key
```

### 配置文件示例

编辑 `~/.config/code-server/config.yaml`：

```yaml
bind-addr: 0.0.0.0:8080      # 监听地址与端口
auth: password               # 认证方式
password: "your-strong-password"
cert: /etc/code-server/ssl/code-server.crt
cert-key: /etc/code-server/ssl/code-server.key
```

**说明**：
- 若设置 `cert: true`，code-server 会自动生成临时自签证书（不推荐生产环境）
- 使用 443 端口需 root 权限或配置反向代理

### 应用配置

```bash
sudo systemctl restart code-server@$(whoami)
sudo systemctl status code-server@$(whoami)
```

### 故障排查

- **无法访问**: 检查防火墙 `sudo firewall-cmd --permanent --add-port=8080/tcp && sudo firewall-cmd --reload`
- **证书错误**: 查看日志 `journalctl -u code-server@$(whoami) -e`
- **权限问题**: 确保私钥权限 `600`，目录权限 `700`

### 反向代理方案

生产环境建议使用 Nginx/Caddy 作为反向代理：

```nginx
# Nginx 配置示例
server {
    listen 443 ssl;
    server_name your.domain.com;

    ssl_certificate /etc/letsencrypt/live/your.domain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/your.domain.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection upgrade;
        proxy_set_header Accept-Encoding gzip;
    }
}
```

此方案下 code-server 监听 `127.0.0.1:8080`，由 Nginx 负责 TLS 终止和证书自动续期。

## 许可证

MIT

## 贡献

欢迎提交 Issue 和 Pull Request！
