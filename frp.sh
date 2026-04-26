#!/usr/bin/env bash
# frp all-in-one installer/manager for Linux
# Supports frp v0.52+ TOML config, systemd, frps/frpc, proxy wizard.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="2026.04.26-r3"
FRP_REPO="fatedier/frp"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/frp"
FRPC_CONF_DIR="/etc/frp/frpc.d"
LOG_DIR="/var/log/frp"
TOKEN_FILE="/etc/frp/token"
FRPS_CONFIG="/etc/frp/frps.toml"
FRPC_CONFIG="/etc/frp/frpc.toml"
FRPC_STORE="/etc/frp/frpc-store.json"
FRP_USER="frp"
GH_API="https://api.github.com/repos/${FRP_REPO}/releases/latest"
GH_RELEASE_BASE="https://github.com/${FRP_REPO}/releases/download"

# ---------- colors ----------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'
else
  C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''
fi

info() { printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$*" >&2; }
ok() { printf '%s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err() { printf '%s[ERR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
fatal() { err "$*"; exit 1; }

trap 'err "脚本在第 ${LINENO} 行失败，命令：${BASH_COMMAND}"' ERR
trap 'printf "\n" >&2; err "已中断。"; exit 130' INT

# ---------- helpers ----------
need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fatal "请使用 root 运行：sudo bash $0"
  fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

pause() { read -r -p "按回车继续..." _ || true; }

trim() {
  local s="$*"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

ask() {
  local prompt="$1" default="${2:-}" ans
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " ans || true
    printf '%s' "${ans:-$default}"
  else
    read -r -p "$prompt: " ans || true
    printf '%s' "$ans"
  fi
}

ask_required() {
  local prompt="$1" default="${2:-}" ans
  while true; do
    ans="$(ask "$prompt" "$default")"
    ans="$(trim "$ans")"
    [[ -n "$ans" ]] && { printf '%s' "$ans"; return; }
    warn "不能为空，请重新输入。"
  done
}

confirm() {
  local prompt="$1" default="${2:-Y}" ans hint
  if [[ "$default" =~ ^[Yy]$ ]]; then hint="Y/n"; else hint="y/N"; fi
  read -r -p "$prompt [$hint]: " ans || true
  ans="${ans:-$default}"
  [[ "$ans" =~ ^[Yy]$ ]]
}

ask_port() {
  local prompt="$1" default="${2:-}" port
  while true; do
    port="$(ask "$prompt" "$default")"
    if [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )); then
      printf '%s' "$port"; return
    fi
    warn "端口必须是 1-65535 的数字。"
  done
}

ask_yes_no_value() {
  local prompt="$1" default="${2:-n}"
  if confirm "$prompt" "$default"; then printf 'true'; else printf 'false'; fi
}

toml_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

toml_string() { printf '"%s"' "$(toml_escape "$1")"; }

toml_array_from_csv() {
  local csv="$1" item out="" oldifs="$IFS"
  IFS=',' read -r -a arr <<< "$csv"
  IFS="$oldifs"
  for item in "${arr[@]}"; do
    item="$(trim "$item")"
    [[ -z "$item" ]] && continue
    if [[ -n "$out" ]]; then out+=", "; fi
    out+="$(toml_string "$item")"
  done
  printf '[%s]' "$out"
}

random_secret() {
  if has_cmd openssl; then
    openssl rand -base64 32 | tr -d '\n'
  else
    tr -dc 'A-Za-z0-9_=-' </dev/urandom | head -c 43 || true
  fi
}

print_banner() {
  clear 2>/dev/null || true
  cat <<BANNER
${C_BOLD}==================================================
       frp 一键安装/管理脚本  ${SCRIPT_VERSION}
       支持 TOML / systemd / frps / frpc
==================================================${C_RESET}
BANNER
}

install_dependencies() {
  local missing=() c
  for c in curl tar gzip grep sed awk uname chmod chown mkdir rm cp mv; do
    has_cmd "$c" || missing+=("$c")
  done
  # openssl is optional but useful for random token.
  has_cmd openssl || missing+=("openssl")

  if (( ${#missing[@]} == 0 )); then
    return
  fi

  warn "缺少依赖：${missing[*]}"
  if ! confirm "是否自动安装依赖" "Y"; then
    fatal "缺少依赖，无法继续。"
  fi

  if has_cmd apt-get; then
    apt-get update
    apt-get install -y curl tar gzip grep sed gawk coreutils openssl ca-certificates
  elif has_cmd dnf; then
    dnf install -y curl tar gzip grep sed gawk coreutils openssl ca-certificates
  elif has_cmd yum; then
    yum install -y curl tar gzip grep sed gawk coreutils openssl ca-certificates
  elif has_cmd apk; then
    apk add --no-cache curl tar gzip grep sed gawk coreutils openssl ca-certificates
  elif has_cmd pacman; then
    pacman -Sy --noconfirm curl tar gzip grep sed gawk coreutils openssl ca-certificates
  else
    fatal "未识别包管理器，请手动安装：${missing[*]}"
  fi
}

detect_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7*) echo "arm" ;;
    armv6l|armv6*) echo "arm" ;;
    i386|i686) echo "386" ;;
    *) fatal "暂不支持架构：$arch" ;;
  esac
}

get_latest_version() {
  local tag
  tag="$(curl -fsSL "$GH_API" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\(v[0-9][^"]*\)".*/\1/p' | head -n1)"
  [[ -n "$tag" ]] || fatal "获取 frp 最新版本失败，可以设置 VERSION=v0.xx.x 后重试。"
  printf '%s' "$tag"
}

select_version() {
  local default_version version
  default_version="${VERSION:-}"
  if [[ -z "$default_version" ]]; then
    info "正在获取 frp 最新版本..."
    default_version="$(get_latest_version)"
  fi
  version="$(ask "请输入 frp 版本，保留默认即最新" "$default_version")"
  [[ "$version" =~ ^v ]] || version="v${version}"
  printf '%s' "$version"
}

create_dirs_and_user() {
  mkdir -p "$CONFIG_DIR" "$FRPC_CONF_DIR" "$LOG_DIR"

  if ! id "$FRP_USER" >/dev/null 2>&1; then
    if has_cmd useradd; then
      useradd --system --no-create-home --shell /usr/sbin/nologin "$FRP_USER" 2>/dev/null || \
      useradd --system --no-create-home --shell /bin/false "$FRP_USER"
    elif has_cmd adduser; then
      adduser -S -D -H -s /sbin/nologin "$FRP_USER" 2>/dev/null || true
    fi
  fi

  if id "$FRP_USER" >/dev/null 2>&1; then
    chown -R root:"$FRP_USER" "$CONFIG_DIR"
    chown -R "$FRP_USER":"$FRP_USER" "$LOG_DIR"
    chmod 750 "$CONFIG_DIR" "$FRPC_CONF_DIR"
  else
    warn "无法创建系统用户 $FRP_USER，将使用 root 运行 systemd 服务。"
  fi
}

download_and_install_frp() {
  local version="$1" arch url tmpdir archive dirname prefix
  arch="$(detect_arch)"
  archive="frp_${version#v}_linux_${arch}.tar.gz"
  url="${GH_RELEASE_BASE}/${version}/${archive}"

  if [[ -n "${GH_PROXY:-}" ]]; then
    prefix="${GH_PROXY%/}/"
    url="${prefix}${url}"
  fi

  tmpdir="$(mktemp -d)"
  info "下载：$url"
  curl -fL --connect-timeout 15 --retry 3 --retry-delay 2 -o "${tmpdir}/${archive}" "$url"
  tar -xzf "${tmpdir}/${archive}" -C "$tmpdir"
  dirname="${tmpdir}/frp_${version#v}_linux_${arch}"
  [[ -x "${dirname}/frps" && -x "${dirname}/frpc" ]] || fatal "压缩包中没有找到 frps/frpc。"

  install -m 0755 "${dirname}/frps" "${INSTALL_DIR}/frps"
  install -m 0755 "${dirname}/frpc" "${INSTALL_DIR}/frpc"
  rm -rf "$tmpdir"

  ok "frp ${version} 已安装到 ${INSTALL_DIR}"
  printf "frps: %s\n" "$(frp_version_text "${INSTALL_DIR}/frps")"
}

ensure_token_file() {
  local token="${1:-}"
  if [[ -z "$token" ]]; then
    if [[ -s "$TOKEN_FILE" ]]; then
      token="$(tr -d '[:space:]' < "$TOKEN_FILE")"
    else
      token="$(random_secret)"
    fi
  fi
  printf '%s\n' "$token" > "$TOKEN_FILE"
  chown root:"$FRP_USER" "$TOKEN_FILE" 2>/dev/null || chown root:root "$TOKEN_FILE"
  chmod 640 "$TOKEN_FILE"
}

write_systemd_service() {
  local name="$1" bin="$2" conf="$3" extra_args="${4:-}" user_line group_line cap_line
  if id "$FRP_USER" >/dev/null 2>&1; then
    user_line="User=${FRP_USER}"
    group_line="Group=${FRP_USER}"
  else
    user_line=""
    group_line=""
  fi

  # Allows binding low ports such as 80/443 when running as non-root.
  cap_line=$'AmbientCapabilities=CAP_NET_BIND_SERVICE\nCapabilityBoundingSet=CAP_NET_BIND_SERVICE'

  cat > "/etc/systemd/system/${name}.service" <<EOF_SERVICE
[Unit]
Description=frp ${name#frp} service
Documentation=https://gofrp.org/zh-cn/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
${user_line}
${group_line}
ExecStart=${bin} -c ${conf}${extra_args:+ ${extra_args}}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
${cap_line}
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${CONFIG_DIR} ${LOG_DIR}

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  systemctl daemon-reload
  ok "已写入 /etc/systemd/system/${name}.service"
}

systemctl_enable_restart() {
  local service="$1"
  systemctl enable "$service" >/dev/null
  systemctl restart "$service"
  ok "${service} 已启动并设置开机自启。"
  systemctl --no-pager --full status "$service" || true
}

try_open_firewall_port() {
  local port="$1" proto="${2:-tcp}"
  [[ -z "$port" ]] && return 0
  if has_cmd ufw && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    if confirm "检测到 UFW，是否放行 ${port}/${proto}" "Y"; then
      ufw allow "${port}/${proto}" || true
    fi
  elif has_cmd firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    if confirm "检测到 firewalld，是否放行 ${port}/${proto}" "Y"; then
      firewall-cmd --permanent --add-port="${port}/${proto}" || true
      firewall-cmd --reload || true
    fi
  fi
}

verify_config() {
  local bin="$1" conf="$2"
  if [[ -x "$bin" && -f "$conf" ]]; then
    info "校验配置：$bin verify -c $conf"
    "$bin" verify -c "$conf"
  fi
}

frp_version_text() {
  local bin="$1" out=""
  [[ -x "$bin" ]] || return 0
  out="$("$bin" version 2>/dev/null || true)"
  [[ -n "$out" ]] || out="$("$bin" -v 2>/dev/null || true)"
  [[ -n "$out" ]] || out="$("$bin" --version 2>/dev/null || true)"
  printf '%s' "$out"
}

# ---------- frps ----------
install_or_update_binaries() {
  install_dependencies
  create_dirs_and_user
  local version
  version="$(select_version)"
  download_and_install_frp "$version"
}

configure_frps() {
  create_dirs_and_user
  local bind_addr bind_port token token_value enable_kcp enable_quic kcp_port quic_port
  local enable_http http_port enable_https https_port subdomain_host
  local enable_dashboard dash_addr dash_port dash_user dash_pass enable_prom max_pool

  echo
  info "配置 frps 服务端"
  bind_addr="$(ask "frps 监听地址" "0.0.0.0")"
  bind_port="$(ask_port "frps 主通信端口 bindPort" "7000")"
  token="$(ask "鉴权 token，留空自动生成/沿用" "")"
  ensure_token_file "$token"
  token_value="$(tr -d '[:space:]' < "$TOKEN_FILE")"

  enable_kcp="$(ask_yes_no_value "是否启用 KCP UDP 通信端口" "n")"
  if [[ "$enable_kcp" == "true" ]]; then
    kcp_port="$(ask_port "KCP UDP 端口 kcpBindPort" "$bind_port")"
  else
    kcp_port=""
  fi

  enable_quic="$(ask_yes_no_value "是否启用 QUIC UDP 通信端口" "n")"
  if [[ "$enable_quic" == "true" ]]; then
    quic_port="$(ask_port "QUIC UDP 端口 quicBindPort" "$bind_port")"
  else
    quic_port=""
  fi

  enable_http="$(ask_yes_no_value "是否启用 HTTP 虚拟主机代理" "n")"
  if [[ "$enable_http" == "true" ]]; then
    http_port="$(ask_port "HTTP 访问端口 vhostHTTPPort" "80")"
  else
    http_port=""
  fi

  enable_https="$(ask_yes_no_value "是否启用 HTTPS 虚拟主机代理" "n")"
  if [[ "$enable_https" == "true" ]]; then
    https_port="$(ask_port "HTTPS 访问端口 vhostHTTPSPort" "443")"
  else
    https_port=""
  fi

  subdomain_host="$(ask "泛域名后缀 subDomainHost，留空跳过，例如 frp.example.com" "")"

  enable_dashboard="$(ask_yes_no_value "是否启用 frps Dashboard / Prometheus" "Y")"
  if [[ "$enable_dashboard" == "true" ]]; then
    dash_addr="$(ask "Dashboard 监听地址，公网访问用 0.0.0.0，本机安全用 127.0.0.1" "0.0.0.0")"
    dash_port="$(ask_port "Dashboard 端口" "7500")"
    dash_user="$(ask "Dashboard 用户名" "admin")"
    dash_pass="$(ask "Dashboard 密码，留空随机生成" "")"
    [[ -z "$dash_pass" ]] && dash_pass="$(random_secret | cut -c1-16)"
    enable_prom="$(ask_yes_no_value "是否启用 Prometheus 指标" "Y")"
  else
    dash_addr=""; dash_port=""; dash_user=""; dash_pass=""; enable_prom="false"
  fi

  max_pool="$(ask_port "服务端允许的最大连接池数量 transport.maxPoolCount" "5")"

  if [[ -f "$FRPS_CONFIG" ]]; then
    cp -a "$FRPS_CONFIG" "${FRPS_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
  fi

  cat > "$FRPS_CONFIG" <<EOF_FRPS
# Generated by frp manager ${SCRIPT_VERSION}
bindAddr = "$(toml_escape "$bind_addr")"
bindPort = ${bind_port}

# Token authentication.
auth.method = "token"
auth.token = "$(toml_escape "$token_value")"

# Transport tuning.
transport.maxPoolCount = ${max_pool}

# Logs.
log.to = "${LOG_DIR}/frps.log"
log.level = "info"
log.maxDays = 7
EOF_FRPS

  [[ -n "$kcp_port" ]] && echo "kcpBindPort = ${kcp_port}" >> "$FRPS_CONFIG"
  [[ -n "$quic_port" ]] && echo "quicBindPort = ${quic_port}" >> "$FRPS_CONFIG"
  [[ -n "$http_port" ]] && echo "vhostHTTPPort = ${http_port}" >> "$FRPS_CONFIG"
  [[ -n "$https_port" ]] && echo "vhostHTTPSPort = ${https_port}" >> "$FRPS_CONFIG"
  [[ -n "$subdomain_host" ]] && echo "subDomainHost = \"$(toml_escape "$subdomain_host")\"" >> "$FRPS_CONFIG"

  if [[ "$enable_dashboard" == "true" ]]; then
    cat >> "$FRPS_CONFIG" <<EOF_FRPS_DASH

# Dashboard / API / Prometheus.
webServer.addr = "$(toml_escape "$dash_addr")"
webServer.port = ${dash_port}
webServer.user = "$(toml_escape "$dash_user")"
webServer.password = "$(toml_escape "$dash_pass")"
enablePrometheus = ${enable_prom}
EOF_FRPS_DASH
  fi

  chown root:"$FRP_USER" "$FRPS_CONFIG" 2>/dev/null || true
  chmod 640 "$FRPS_CONFIG"
  verify_config "${INSTALL_DIR}/frps" "$FRPS_CONFIG"

  write_systemd_service "frps" "${INSTALL_DIR}/frps" "$FRPS_CONFIG"
  if confirm "是否现在启动/重启 frps" "Y"; then
    systemctl_enable_restart frps
  fi

  try_open_firewall_port "$bind_port" "tcp"
  [[ -n "$kcp_port" ]] && try_open_firewall_port "$kcp_port" "udp"
  [[ -n "$quic_port" ]] && try_open_firewall_port "$quic_port" "udp"
  [[ -n "$http_port" ]] && try_open_firewall_port "$http_port" "tcp"
  [[ -n "$https_port" ]] && try_open_firewall_port "$https_port" "tcp"
  [[ -n "$dash_port" ]] && try_open_firewall_port "$dash_port" "tcp"

  echo
  ok "frps 配置完成：$FRPS_CONFIG"
  echo "Token 文件：$TOKEN_FILE"
  if [[ "$enable_dashboard" == "true" ]]; then
    echo "Dashboard: http://${dash_addr}:${dash_port}  用户：${dash_user}  密码：${dash_pass}"
  fi
}

install_frps_flow() {
  install_or_update_binaries
  configure_frps
}

# ---------- frpc ----------
configure_frpc() {
  create_dirs_and_user
  local server_addr server_port token token_value user_name proto tls_enable pool_count dns_server
  local enable_admin admin_addr admin_port admin_user admin_pass enable_store

  echo
  info "配置 frpc 客户端"
  server_addr="$(ask_required "frps 服务器地址 serverAddr/IP/域名" "")"
  server_port="$(ask_port "frps 服务器端口 serverPort" "7000")"
  token="$(ask "鉴权 token，留空自动生成/沿用 ${TOKEN_FILE}" "")"
  ensure_token_file "$token"
  token_value="$(tr -d '[:space:]' < "$TOKEN_FILE")"
  user_name="$(ask "客户端 user，留空不设置；多人共用服务端建议填写" "")"

  echo "通信协议可选：tcp / kcp / quic / websocket / wss"
  proto="$(ask "transport.protocol" "tcp")"
  case "$proto" in tcp|kcp|quic|websocket|wss) ;; *) warn "未知协议，回退 tcp"; proto="tcp" ;; esac
  tls_enable="$(ask_yes_no_value "是否启用 frpc->frps TLS；新版默认启用，建议保留" "Y")"
  pool_count="$(ask "连接池数量 transport.poolCount，普通场景 0，短连接高并发可 1-5" "0")"
  [[ "$pool_count" =~ ^[0-9]+$ ]] || pool_count=0
  dns_server="$(ask "自定义 DNS 服务器，留空使用系统 DNS，例如 1.1.1.1" "")"

  enable_admin="$(ask_yes_no_value "是否启用 frpc Admin UI / 动态代理管理" "Y")"
  if [[ "$enable_admin" == "true" ]]; then
    admin_addr="$(ask "Admin UI 监听地址，建议 127.0.0.1" "127.0.0.1")"
    admin_port="$(ask_port "Admin UI 端口" "7400")"
    admin_user="$(ask "Admin UI 用户名" "admin")"
    admin_pass="$(ask "Admin UI 密码，留空随机生成" "")"
    [[ -z "$admin_pass" ]] && admin_pass="$(random_secret | cut -c1-16)"
    enable_store="$(ask_yes_no_value "是否启用 Store 动态代理持久化" "Y")"
  else
    admin_addr=""; admin_port=""; admin_user=""; admin_pass=""; enable_store="false"
  fi

  if [[ -f "$FRPC_CONFIG" ]]; then
    cp -a "$FRPC_CONFIG" "${FRPC_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
  fi

  cat > "$FRPC_CONFIG" <<EOF_FRPC
# Generated by frp manager ${SCRIPT_VERSION}
serverAddr = "$(toml_escape "$server_addr")"
serverPort = ${server_port}
loginFailExit = true
includes = ["${FRPC_CONF_DIR}/*.toml"]

# Token authentication.
auth.method = "token"
auth.token = "$(toml_escape "$token_value")"

# Transport.
transport.protocol = "${proto}"
transport.tls.enable = ${tls_enable}
transport.poolCount = ${pool_count}

# Logs.
log.to = "${LOG_DIR}/frpc.log"
log.level = "info"
log.maxDays = 7
EOF_FRPC

  [[ -n "$user_name" ]] && echo "user = \"$(toml_escape "$user_name")\"" >> "$FRPC_CONFIG"
  [[ -n "$dns_server" ]] && echo "dnsServer = \"$(toml_escape "$dns_server")\"" >> "$FRPC_CONFIG"

  if [[ "$enable_admin" == "true" ]]; then
    cat >> "$FRPC_CONFIG" <<EOF_FRPC_ADMIN

# Admin UI / runtime proxy management.
webServer.addr = "$(toml_escape "$admin_addr")"
webServer.port = ${admin_port}
webServer.user = "$(toml_escape "$admin_user")"
webServer.password = "$(toml_escape "$admin_pass")"
EOF_FRPC_ADMIN
    if [[ "$enable_store" == "true" ]]; then
      cat >> "$FRPC_CONFIG" <<EOF_FRPC_STORE

[store]
path = "${FRPC_STORE}"
EOF_FRPC_STORE
    fi
  fi

  chown root:"$FRP_USER" "$FRPC_CONFIG" 2>/dev/null || true
  chmod 640 "$FRPC_CONFIG"
  verify_config "${INSTALL_DIR}/frpc" "$FRPC_CONFIG"

  write_systemd_service "frpc" "${INSTALL_DIR}/frpc" "$FRPC_CONFIG"
  if confirm "是否现在启动/重启 frpc" "Y"; then
    systemctl_enable_restart frpc
  fi

  echo
  ok "frpc 主配置完成：$FRPC_CONFIG"
  echo "代理拆分配置目录：$FRPC_CONF_DIR"
  if [[ "$enable_admin" == "true" ]]; then
    echo "Admin UI: http://${admin_addr}:${admin_port}  用户：${admin_user}  密码：${admin_pass}"
  fi
}

install_frpc_flow() {
  install_or_update_binaries
  configure_frpc
}

append_common_proxy_options() {
  local file="$1" type="$2"
  local use_comp bw health hc_type hc_path
  if confirm "是否启用该代理的压缩 transport.useCompression" "n"; then
    echo "transport.useCompression = true" >> "$file"
  fi
  bw="$(ask "限速 bandwidthLimit，留空不限制，例如 10MB 或 512KB" "")"
  if [[ -n "$bw" ]]; then
    echo "transport.bandwidthLimit = \"$(toml_escape "$bw")\"" >> "$file"
    echo "transport.bandwidthLimitMode = \"client\"" >> "$file"
  fi
  if [[ "$type" == "tcp" || "$type" == "http" || "$type" == "https" ]]; then
    if confirm "是否添加健康检查" "n"; then
      if [[ "$type" == "http" || "$type" == "https" ]]; then
        hc_type="http"
        hc_path="$(ask "健康检查路径" "/")"
        echo "healthCheck.type = \"http\"" >> "$file"
        echo "healthCheck.path = \"$(toml_escape "$hc_path")\"" >> "$file"
      else
        echo "healthCheck.type = \"tcp\"" >> "$file"
      fi
      echo "healthCheck.intervalSeconds = 10" >> "$file"
      echo "healthCheck.timeoutSeconds = 3" >> "$file"
      echo "healthCheck.maxFailed = 3" >> "$file"
    fi
  fi
}

add_proxy_tcp_udp() {
  local type="$1" name="$2" file="$3" local_ip local_port remote_port
  local_ip="$(ask "本地服务 IP localIP" "127.0.0.1")"
  local_port="$(ask_port "本地服务端口 localPort" "")"
  remote_port="$(ask_port "服务端暴露端口 remotePort" "")"
  cat > "$file" <<EOF_PROXY
[[proxies]]
name = "$(toml_escape "$name")"
type = "${type}"
localIP = "$(toml_escape "$local_ip")"
localPort = ${local_port}
remotePort = ${remote_port}
EOF_PROXY
  append_common_proxy_options "$file" "$type"
}

add_proxy_http_https() {
  local type="$1" name="$2" file="$3" local_ip local_port domain_mode domains subdomain
  local locations host_rewrite http_user http_pass
  local_ip="$(ask "本地 Web 服务 IP localIP" "127.0.0.1")"
  local_port="$(ask_port "本地 Web 服务端口 localPort" "80")"
  cat > "$file" <<EOF_PROXY
[[proxies]]
name = "$(toml_escape "$name")"
type = "${type}"
localIP = "$(toml_escape "$local_ip")"
localPort = ${local_port}
EOF_PROXY

  echo "域名方式：1) customDomains 自定义域名  2) subdomain 二级域名  3) 两者都写"
  domain_mode="$(ask "请选择" "1")"
  if [[ "$domain_mode" == "1" || "$domain_mode" == "3" ]]; then
    domains="$(ask_required "customDomains，多个用英文逗号分隔" "")"
    echo "customDomains = $(toml_array_from_csv "$domains")" >> "$file"
  fi
  if [[ "$domain_mode" == "2" || "$domain_mode" == "3" ]]; then
    subdomain="$(ask_required "subdomain，例如 nas -> nas.your-frps-domain.com" "")"
    echo "subdomain = \"$(toml_escape "$subdomain")\"" >> "$file"
  fi

  # locations / hostHeaderRewrite / httpUser / httpPassword are HTTP-only fields.
  if [[ "$type" == "http" ]]; then
    locations="$(ask "URL 路由 locations，多个逗号分隔；留空不设置，例如 /api,/static" "")"
    [[ -n "$locations" ]] && echo "locations = $(toml_array_from_csv "$locations")" >> "$file"
    host_rewrite="$(ask "Host Header 重写 hostHeaderRewrite，留空不设置" "")"
    [[ -n "$host_rewrite" ]] && echo "hostHeaderRewrite = \"$(toml_escape "$host_rewrite")\"" >> "$file"

    if confirm "是否给该 HTTP 代理添加 BasicAuth" "n"; then
      http_user="$(ask_required "HTTP BasicAuth 用户名" "admin")"
      http_pass="$(ask "HTTP BasicAuth 密码，留空随机" "")"
      [[ -z "$http_pass" ]] && http_pass="$(random_secret | cut -c1-16)"
      echo "httpUser = \"$(toml_escape "$http_user")\"" >> "$file"
      echo "httpPassword = \"$(toml_escape "$http_pass")\"" >> "$file"
      ok "HTTP BasicAuth：${http_user} / ${http_pass}"
    fi
  fi

  append_common_proxy_options "$file" "$type"
}

add_proxy_stcp_xtcp_sudp() {
  local type="$1" name="$2" file="$3" local_ip local_port secret allow_users
  local_ip="$(ask "本地服务 IP localIP" "127.0.0.1")"
  local_port="$(ask_port "本地服务端口 localPort" "22")"
  secret="$(ask "secretKey，留空随机生成" "")"
  [[ -z "$secret" ]] && secret="$(random_secret)"
  allow_users="$(ask "allowUsers，留空默认同 user；允许所有 visitor 填 *" "")"

  cat > "$file" <<EOF_PROXY
[[proxies]]
name = "$(toml_escape "$name")"
type = "${type}"
secretKey = "$(toml_escape "$secret")"
localIP = "$(toml_escape "$local_ip")"
localPort = ${local_port}
EOF_PROXY
  [[ -n "$allow_users" ]] && echo "allowUsers = $(toml_array_from_csv "$allow_users")" >> "$file"
  append_common_proxy_options "$file" "$type"
  ok "secretKey：$secret"
}

add_visitor_stcp_xtcp_sudp() {
  local type="$1" name="$2" file="$3" server_name secret bind_addr bind_port
  server_name="$(ask_required "要访问的服务端代理名 serverName" "")"
  secret="$(ask_required "secretKey，需要和服务端代理一致" "")"
  bind_addr="$(ask "本机访问监听地址 bindAddr" "127.0.0.1")"
  bind_port="$(ask_port "本机访问监听端口 bindPort" "6000")"
  cat > "$file" <<EOF_VISITOR
[[visitors]]
name = "$(toml_escape "$name")"
type = "${type}"
serverName = "$(toml_escape "$server_name")"
secretKey = "$(toml_escape "$secret")"
bindAddr = "$(toml_escape "$bind_addr")"
bindPort = ${bind_port}
EOF_VISITOR
}

add_proxy_wizard() {
  create_dirs_and_user
  [[ -f "$FRPC_CONFIG" ]] || warn "未检测到 $FRPC_CONFIG，建议先安装/配置 frpc。"
  local type name safe_name file
  echo
  info "添加 frpc 代理/访问者配置"
  echo "支持类型：tcp udp http https stcp xtcp sudp stcp-visitor xtcp-visitor sudp-visitor"
  type="$(ask "类型" "tcp")"
  case "$type" in tcp|udp|http|https|stcp|xtcp|sudp|stcp-visitor|xtcp-visitor|sudp-visitor) ;; *) fatal "不支持的类型：$type" ;; esac
  name="$(ask_required "名称 name，必须唯一" "")"
  safe_name="$(printf '%s' "$name" | sed 's/[^A-Za-z0-9._-]/_/g')"
  file="${FRPC_CONF_DIR}/${safe_name}.toml"

  if [[ -f "$file" ]]; then
    if confirm "配置 ${file} 已存在，是否覆盖" "n"; then
      cp -a "$file" "${file}.bak.$(date +%Y%m%d-%H%M%S)"
    else
      return
    fi
  fi

  case "$type" in
    tcp|udp) add_proxy_tcp_udp "$type" "$name" "$file" ;;
    http|https) add_proxy_http_https "$type" "$name" "$file" ;;
    stcp|xtcp|sudp) add_proxy_stcp_xtcp_sudp "$type" "$name" "$file" ;;
    stcp-visitor) add_visitor_stcp_xtcp_sudp "stcp" "$name" "$file" ;;
    xtcp-visitor) add_visitor_stcp_xtcp_sudp "xtcp" "$name" "$file" ;;
    sudp-visitor) add_visitor_stcp_xtcp_sudp "sudp" "$name" "$file" ;;
  esac

  chown root:"$FRP_USER" "$file" 2>/dev/null || true
  chmod 640 "$file"
  ok "已写入：$file"

  verify_config "${INSTALL_DIR}/frpc" "$FRPC_CONFIG"
  if systemctl list-unit-files frpc.service >/dev/null 2>&1; then
    if confirm "是否重启 frpc 使配置生效" "Y"; then
      systemctl restart frpc
      systemctl --no-pager --full status frpc || true
    fi
  fi
}

# ---------- management ----------
show_summary() {
  echo
  echo "安装目录：${INSTALL_DIR}"
  [[ -x "${INSTALL_DIR}/frps" ]] && echo "frps：$(frp_version_text "${INSTALL_DIR}/frps")"
  [[ -x "${INSTALL_DIR}/frpc" ]] && echo "frpc：$(frp_version_text "${INSTALL_DIR}/frpc")"
  echo "配置目录：${CONFIG_DIR}"
  echo "frps 配置：${FRPS_CONFIG}"
  echo "frpc 配置：${FRPC_CONFIG}"
  echo "frpc 拆分代理：${FRPC_CONF_DIR}"
  echo "日志目录：${LOG_DIR}"
  echo
  if has_cmd systemctl; then
    systemctl --no-pager --full status frps 2>/dev/null || true
    systemctl --no-pager --full status frpc 2>/dev/null || true
  fi
}

manage_service_menu() {
  local svc action
  echo "服务：1) frps  2) frpc"
  svc="$(ask "请选择" "1")"
  case "$svc" in 1|frps) svc="frps" ;; 2|frpc) svc="frpc" ;; *) warn "无效选择"; return ;; esac
  echo "操作：1) status  2) start  3) stop  4) restart  5) logs -f  6) enable  7) disable"
  action="$(ask "请选择" "1")"
  case "$action" in
    1|status) systemctl --no-pager --full status "$svc" || true ;;
    2|start) systemctl start "$svc"; systemctl --no-pager --full status "$svc" || true ;;
    3|stop) systemctl stop "$svc" ;;
    4|restart) systemctl restart "$svc"; systemctl --no-pager --full status "$svc" || true ;;
    5|logs) journalctl -u "$svc" -n 100 -f ;;
    6|enable) systemctl enable "$svc" ;;
    7|disable) systemctl disable "$svc" ;;
    *) warn "无效选择" ;;
  esac
}

verify_all_configs() {
  [[ -x "${INSTALL_DIR}/frps" && -f "$FRPS_CONFIG" ]] && verify_config "${INSTALL_DIR}/frps" "$FRPS_CONFIG"
  [[ -x "${INSTALL_DIR}/frpc" && -f "$FRPC_CONFIG" ]] && verify_config "${INSTALL_DIR}/frpc" "$FRPC_CONFIG"
}

uninstall_frp() {
  warn "即将卸载 frp。"
  if ! confirm "确认继续" "n"; then return; fi
  systemctl stop frps frpc 2>/dev/null || true
  systemctl disable frps frpc 2>/dev/null || true
  rm -f /etc/systemd/system/frps.service /etc/systemd/system/frpc.service
  systemctl daemon-reload 2>/dev/null || true
  rm -f "${INSTALL_DIR}/frps" "${INSTALL_DIR}/frpc"
  if confirm "是否删除配置目录 ${CONFIG_DIR}" "n"; then
    rm -rf "$CONFIG_DIR"
  fi
  if confirm "是否删除日志目录 ${LOG_DIR}" "n"; then
    rm -rf "$LOG_DIR"
  fi
  ok "卸载完成。"
}

main_menu() {
  need_root
  while true; do
    print_banner
    cat <<MENU
1) 安装/更新 frps 服务端
2) 安装/更新 frpc 客户端
3) 仅安装/更新 frp 二进制文件
4) 添加 frpc 代理/访问者
5) 管理 systemd 服务
6) 校验配置
7) 查看安装摘要
8) 卸载 frp
0) 退出
MENU
    local choice
    choice="$(ask "请选择" "1")"
    case "$choice" in
      1) install_frps_flow; pause ;;
      2) install_frpc_flow; pause ;;
      3) install_or_update_binaries; pause ;;
      4) add_proxy_wizard; pause ;;
      5) manage_service_menu; pause ;;
      6) verify_all_configs; pause ;;
      7) show_summary; pause ;;
      8) uninstall_frp; pause ;;
      0|q|Q) exit 0 ;;
      *) warn "无效选择"; pause ;;
    esac
  done
}

if [[ "${FRP_LIB_ONLY:-0}" != "1" ]]; then
  main_menu "$@"
fi
