#!/usr/bin/env bash
set -euo pipefail

# Caddy 自动安装脚本
# 从 GitHub Release 下载并安装 Caddy 到系统

REPO_OWNER="${REPO_OWNER:-satifanie}"
REPO_NAME="${REPO_NAME:-server-binary}"
RELEASE_TAG="${RELEASE_TAG:-caddy}"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/caddy"
DATA_DIR="/var/lib/caddy"
LOG_DIR="/var/log/caddy"
TEMP_DIR=""
CADDY_BINARY=""
cleanup() {
    if [[ -n "${TEMP_DIR}" ]]; then
        rm -rf -- "${TEMP_DIR}"
    fi
}
trap cleanup EXIT

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# 检测操作系统和架构
detect_platform() {
    local os arch
    
    case "$(uname -s)" in
        Linux*)  os="linux" ;;
        Darwin*) os="darwin" ;;
        MINGW*|MSYS*|CYGWIN*) os="windows" ;;
        *) log_error "不支持的操作系统: $(uname -s)"; exit 1 ;;
    esac
    
    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) log_error "不支持的架构: $(uname -m)"; exit 1 ;;
    esac
    
    echo "${os}-${arch}"
}

# 下载 Caddy 二进制
download_caddy() {
    local platform="$1"
    local ext="tar.gz" binary_name="caddy"
    if [[ "$platform" == windows-* ]]; then
        ext="zip"
        binary_name="caddy.exe"
    fi

    local asset_name="caddy-${platform}.${ext}"
    local download_url="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${RELEASE_TAG}/${asset_name}"
    local temp_file
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/caddy-install.XXXXXX")
    temp_file="${TEMP_DIR}/${asset_name}"
    curl --fail --location --silent --show-error --retry 3 --output "${temp_file}" "${download_url}"
    if curl --fail --location --silent --show-error --retry 3 --output "${temp_file}.sha256" "${download_url}.sha256"; then
        local expected_checksum actual_checksum
        expected_checksum=$(cut -d ' ' -f 1 "${temp_file}.sha256")
        if command -v sha256sum >/dev/null; then
            actual_checksum=$(sha256sum "${temp_file}" | cut -d ' ' -f 1)
        elif command -v shasum >/dev/null; then
            actual_checksum=$(shasum -a 256 "${temp_file}" | cut -d ' ' -f 1)
        else
            log_error "缺少 sha256sum 或 shasum 命令，无法校验 Caddy 文件"
            exit 1
        fi
        if [[ ! "${expected_checksum}" =~ ^[[:xdigit:]]{64}$ ]] || [[ "${expected_checksum}" != "${actual_checksum}" ]]; then
            log_error "Caddy 下载文件的 SHA256 校验失败"
            exit 1
        fi
    else
        log_warn "未找到 SHA256 校验文件，跳过完整性校验"
    fi

    log_info "解压 Caddy"
    if [[ "${ext}" == "zip" ]]; then
        command -v unzip >/dev/null || { log_error "缺少 unzip 命令"; exit 1; }
        unzip -q "${temp_file}" -d "${TEMP_DIR}"
    else
        tar -xzf "${temp_file}" -C "${TEMP_DIR}"
    fi

    if [[ ! -f "${TEMP_DIR}/${binary_name}" ]]; then
        log_error "解压后未找到 ${binary_name} 二进制文件"
        exit 1
    fi

    CADDY_BINARY="${TEMP_DIR}/${binary_name}"
}

# 创建系统用户（仅 Linux）
create_user() {
    [[ "$(uname -s)" == "Linux" ]] || return 0

    if ! getent group caddy >/dev/null; then
        log_info "创建系统组 caddy"
        groupadd --system caddy
    fi

    if ! id caddy >/dev/null 2>&1; then
        log_info "创建系统用户 caddy"
        useradd --system \
            --gid caddy \
            --create-home \
            --home-dir "${DATA_DIR}" \
            --shell /usr/sbin/nologin \
            --comment "Caddy web server" \
            caddy
    else
        log_warn "用户 caddy 已存在，跳过创建"
    fi

    if getent group www-data >/dev/null; then
        usermod -aG www-data caddy
    fi
}

# 创建目录结构
create_directories() {
    log_info "创建目录结构"
    mkdir -p "${CONFIG_DIR}" "${DATA_DIR}" "${LOG_DIR}"

    if [[ "$(uname -s)" == "Linux" ]]; then
        chown -R caddy:caddy "${DATA_DIR}" "${LOG_DIR}"
        chown root:caddy "${CONFIG_DIR}"
        chmod 750 "${CONFIG_DIR}"
    fi
}

# 安装 systemd 服务
install_systemd_service() {
    if [[ "$(uname -s)" != "Linux" ]] || [[ ! -d /etc/systemd/system ]]; then
        log_warn "systemd 不可用，跳过服务安装"
        return 0
    fi
    
    log_info "安装 systemd 服务"
    
    cat > /etc/systemd/system/caddy.service <<'EOF'
[Unit]
Description=Caddy Web Server
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
EnvironmentFile=-/etc/caddy/caddy.env
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE
WorkingDirectory=/var/lib/caddy

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    log_info "systemd 服务已安装，使用以下命令管理："
    echo "  启动: sudo systemctl start caddy"
    echo "  开机自启: sudo systemctl enable caddy"
    echo "  查看状态: sudo systemctl status caddy"
}

# 创建示例配置
create_sample_config() {
    if [[ ! -f "${CONFIG_DIR}/Caddyfile" ]]; then
        log_info "创建示例配置文件"
        cat > "${CONFIG_DIR}/Caddyfile" <<'EOF'
# Caddy 配置文件
# 文档: https://caddyserver.com/docs/caddyfile

# example.com {
#     reverse_proxy localhost:8080
# }
EOF
    else
        log_warn "配置文件已存在: ${CONFIG_DIR}/Caddyfile"
    fi

    if [[ ! -f "${CONFIG_DIR}/caddy.env" ]]; then
        cat > "${CONFIG_DIR}/caddy.env" <<'EOF'
# Caddy 环境变量
# CLOUDFLARE_API_TOKEN=your_token_here
# ACME_EMAIL=admin@example.com
EOF
    fi

    if [[ "$(uname -s)" == "Linux" ]]; then
        chown root:caddy "${CONFIG_DIR}/Caddyfile" "${CONFIG_DIR}/caddy.env"
        chmod 640 "${CONFIG_DIR}/Caddyfile" "${CONFIG_DIR}/caddy.env"
    fi
}

# 主安装流程
main() {
    log_info "开始安装 Caddy"
    
    # 检查权限（Linux 需要 root）
    if [[ "$(uname -s)" == "Linux" ]] && [[ $EUID -ne 0 ]]; then
        log_error "请使用 root 权限运行此脚本: sudo $0"
        exit 1
    fi
    
    # 检测平台
    local platform binary_name="caddy"
    platform=$(detect_platform)
    [[ "$platform" == windows-* ]] && binary_name="caddy.exe"
    log_info "检测到平台: ${platform}"

    mkdir -p "${INSTALL_DIR}"

    if [[ -f "${INSTALL_DIR}/${binary_name}" ]]; then
        log_warn "Caddy 已安装，将覆盖现有版本"
        if command -v systemctl >/dev/null && systemctl is-active --quiet caddy 2>/dev/null; then
            log_info "停止 Caddy 服务"
            systemctl stop caddy
        fi
    fi


    # 下载
    download_caddy "${platform}"
    local caddy_binary="${CADDY_BINARY}"

    # 安装二进制
    log_info "安装 Caddy 到 ${INSTALL_DIR}/${binary_name}"
    install -m 755 "${caddy_binary}" "${INSTALL_DIR}/${binary_name}"
    
    # 验证安装
    if ! "${INSTALL_DIR}/${binary_name}" version &>/dev/null; then
        log_error "Caddy 安装失败，二进制文件无法运行"
        exit 1
    fi
    
    log_info "Caddy 版本: $("${INSTALL_DIR}/${binary_name}" version)"
    
    # 创建用户和目录
    create_user
    create_directories
    create_sample_config
    install_systemd_service
    
    # 临时目录由 EXIT trap 清理
    
    log_info "✅ Caddy 安装完成！"
    echo ""
    echo "配置文件: ${CONFIG_DIR}/Caddyfile"
    echo "环境变量: ${CONFIG_DIR}/caddy.env"
    echo "数据目录: ${DATA_DIR}"
    if [[ "$(uname -s)" == "Linux" ]] && command -v systemctl >/dev/null; then
        echo "启动服务: sudo systemctl start caddy"
    else
        echo "手动运行: caddy run --config ${CONFIG_DIR}/Caddyfile"
    fi
    
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
