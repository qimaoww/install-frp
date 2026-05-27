#!/usr/bin/env bash
# frp all-in-one installer/manager for Linux
# Supports frp v0.52+ TOML config, systemd, frps/frpc, proxy wizard.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="${SCRIPT_VERSION:-2026.05.28-r24}"
SCRIPT_RAW_URL="${SCRIPT_RAW_URL:-https://raw.githubusercontent.com/qimaoww/install-frp/main/frp.sh}"
FRP_REPO="${FRP_REPO:-fatedier/frp}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
CONFIG_DIR="${CONFIG_DIR:-/etc/frp}"
FRPC_CONF_DIR="${FRPC_CONF_DIR:-${CONFIG_DIR}/frpc.d}"
FRPC_CLIENTS_DIR="${FRPC_CLIENTS_DIR:-${CONFIG_DIR}/clients}"
PRESET_DIR="${PRESET_DIR:-${CONFIG_DIR}/presets.d}"
LOG_DIR="${LOG_DIR:-/var/log/frp}"
TOKEN_FILE="${TOKEN_FILE:-${CONFIG_DIR}/token}"
FRPS_CONFIG="${FRPS_CONFIG:-${CONFIG_DIR}/frps.toml}"
FRPC_CONFIG="${FRPC_CONFIG:-${CONFIG_DIR}/frpc.toml}"
FRPC_STORE="${FRPC_STORE:-${CONFIG_DIR}/frpc-store.json}"
INSTALLER_CONFIG="${INSTALLER_CONFIG:-${CONFIG_DIR}/installer.env}"
INSTALLER_LOG="${INSTALLER_LOG:-${LOG_DIR}/installer.log}"
FRP_USER="${FRP_USER:-frp}"
GH_API="${GH_API:-https://api.github.com/repos/${FRP_REPO}/releases/latest}"
GH_RELEASE_BASE="${GH_RELEASE_BASE:-https://github.com/${FRP_REPO}/releases/download}"
GH_PROXY="${GH_PROXY:-}"

# ---------- colors ----------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_MAGENTA=$'\033[35m'
  C_CYAN=$'\033[36m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
else
  C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_MAGENTA=''; C_CYAN=''; C_DIM=''; C_BOLD=''
fi

log_event() {
  local level="$1" msg="$2" ts
  ts="$(date '+%F %T %z' 2>/dev/null || printf 'unknown-time')"
  { mkdir -p "$LOG_DIR" && printf '%s [%s] %s\n' "$ts" "$level" "$msg" >> "$INSTALLER_LOG"; } 2>/dev/null || true
}

info() { log_event "INFO" "$*"; printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$*" >&2; }
ok() { log_event "OK" "$*"; printf '%s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn() { log_event "WARN" "$*"; printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err() { log_event "ERR" "$*"; printf '%s[ERR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
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

ui_rule() {
  printf '%s%s%s\n' "$C_DIM" "----------------------------------------" "$C_RESET"
}

ui_header() {
  local title="$1" subtitle="${2:-}"
  printf '%s%s%s\n' "$C_BOLD$C_CYAN" "$title" "$C_RESET"
  [[ -n "$subtitle" ]] && printf '%s%s%s\n' "$C_DIM" "$subtitle" "$C_RESET"
  ui_rule
}

ui_menu_item() {
  local key="$1" label="$2" hint="${3:-}"
  if [[ -n "$hint" ]]; then
    printf '%s%s)%s %s %s%s%s\n' "$C_GREEN" "$key" "$C_RESET" "$label" "$C_DIM" "$hint" "$C_RESET"
  else
    printf '%s%s)%s %s\n' "$C_GREEN" "$key" "$C_RESET" "$label"
  fi
}

ui_menu_back() {
  local label="${1:-返回}"
  printf '%s0)%s %s\n' "$C_YELLOW" "$C_RESET" "$label"
}

ui_state() {
  local text="$1" color="$C_DIM"
  case "$text" in
    运行|运行中|active|已配置|自启|enabled|ok|OK) color="$C_GREEN" ;;
    停止|未运行|未自启|disabled|空配置|静态) color="$C_YELLOW" ;;
    失败|异常|failed|未安装|未配置|未装服务) color="$C_RED" ;;
    *) color="$C_DIM" ;;
  esac
  printf '%s%s%s' "$color" "$text" "$C_RESET"
}

ui_service_state() {
  local state="$1" active enabled
  if [[ "$state" == */* ]]; then
    active="${state%%/*}"
    enabled="${state#*/}"
    printf '%s/%s' "$(ui_state "$active")" "$(ui_state "$enabled")"
  else
    ui_state "$state"
  fi
}

menu_title() {
  clear 2>/dev/null || true
  ui_header "$1"
}

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

normalize_github_proxy() {
  local proxy="${1:-}"
  proxy="$(trim "$proxy")"
  [[ -z "$proxy" ]] && { printf ''; return; }
  proxy="${proxy%/}/"
  printf '%s' "$proxy"
}

apply_github_proxy() {
  local url="$1" proxy
  proxy="$(normalize_github_proxy "${GH_PROXY:-}")"
  if [[ -n "$proxy" ]]; then
    printf '%s%s' "$proxy" "$url"
  else
    printf '%s' "$url"
  fi
}

load_installer_config() {
  # Environment variable has higher priority than saved config.
  [[ -n "${GH_PROXY:-}" ]] && { GH_PROXY="$(normalize_github_proxy "$GH_PROXY")"; return; }
  [[ -f "$INSTALLER_CONFIG" ]] || return 0
  local line value
  line="$(grep -E '^GH_PROXY=' "$INSTALLER_CONFIG" | tail -n1 || true)"
  [[ -n "$line" ]] || return 0
  value="${line#GH_PROXY=}"
  value="$(trim "$value")"
  GH_PROXY="$(normalize_github_proxy "$value")"
}

save_installer_config() {
  mkdir -p "$CONFIG_DIR"
  GH_PROXY="$(normalize_github_proxy "${GH_PROXY:-}")"
  cat > "$INSTALLER_CONFIG" <<EOF_INSTALLER
# Generated by frp manager ${SCRIPT_VERSION}
# GitHub proxy prefix. Empty means direct connection.
# Example: https://ghfast.top/
GH_PROXY=${GH_PROXY}
EOF_INSTALLER
  chmod 640 "$INSTALLER_CONFIG" 2>/dev/null || true
  chown root:"$FRP_USER" "$INSTALLER_CONFIG" 2>/dev/null || chown root:root "$INSTALLER_CONFIG" 2>/dev/null || true
}

configure_github_proxy() {
  load_installer_config
  echo
  info "配置 GitHub 下载代理"
  echo "当前代理：${GH_PROXY:-直连}"
  cat <<'EOF_PROXY_HELP'
说明：这里填写“代理前缀”，脚本会把完整 GitHub URL 拼到后面。
示例：
  https://ghfast.top/
  https://gh-proxy.com/
  https://gh.llkk.cc/
留空则恢复直连。
也可以临时使用环境变量：GH_PROXY=https://ghfast.top/ bash frp.sh
EOF_PROXY_HELP
  local input
  input="$(ask "请输入 GitHub 代理前缀，留空直连" "${GH_PROXY:-}")"
  input="$(trim "$input")"
  if [[ -n "$input" && ! "$input" =~ ^https?:// ]]; then
    warn "代理前缀通常应以 http:// 或 https:// 开头，当前仍按原样保存。"
  fi
  GH_PROXY="$(normalize_github_proxy "$input")"
  save_installer_config
  if [[ -n "$GH_PROXY" ]]; then
    ok "已保存 GitHub 代理：$GH_PROXY"
    echo "测试拼接：$(apply_github_proxy "https://github.com/${FRP_REPO}/releases/download/v0.68.1/frp_0.68.1_linux_amd64.tar.gz")"
  else
    ok "已恢复 GitHub 直连下载。"
  fi
}

random_secret() {
  if has_cmd openssl; then
    openssl rand -base64 32 | tr -d '\n'
  else
    tr -dc 'A-Za-z0-9_=-' </dev/urandom | head -c 43 || true
  fi
}

encrypt_payload_code() {
  local prefix="$1" passphrase="$2" payload="$3" cipher
  has_cmd openssl || fatal "需要 openssl 才能生成加密导入码。"
  [[ -n "$passphrase" ]] || fatal "加密口令不能为空。"
  cipher="$(printf '%s' "$payload" | openssl enc -aes-256-cbc -pbkdf2 -salt -base64 -A -pass "pass:${passphrase}")"
  printf '%s:%s' "$prefix" "$cipher"
}

decrypt_payload_code() {
  local prefix="$1" passphrase="$2" code="$3" cipher
  has_cmd openssl || fatal "需要 openssl 才能解密导入码。"
  [[ -n "$passphrase" ]] || fatal "解密口令不能为空。"
  case "$code" in
    "${prefix}:"*) cipher="${code#${prefix}:}" ;;
    *) fatal "导入码前缀不正确，期望 ${prefix}:..." ;;
  esac
  printf '%s' "$cipher" | openssl enc -aes-256-cbc -pbkdf2 -d -base64 -A -pass "pass:${passphrase}"
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

render_one_click_import_command() {
  local kind="$1" code="$2" passphrase="$3" target="${4:-default}" flag
  case "$kind" in
    frps) flag="--import-frps-code" ;;
    xtcp) flag="--import-xtcp-code" ;;
    *) fatal "未知的一键导入类型：$kind" ;;
  esac
  printf 'bash <(curl -fsSL %s) %s %s %s %s\n' \
    "$(shell_quote "$SCRIPT_RAW_URL")" \
    "$flag" \
    "$(shell_quote "$code")" \
    "$(shell_quote "$passphrase")" \
    "$(shell_quote "$target")"
}

parse_payload_value() {
  local payload="$1" key="$2"
  awk -v want="$key" '
    function trim(s) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      return s
    }
    {
      line=$0
      pos=index(line, "=")
      if (pos == 0) next
      k=trim(substr(line, 1, pos-1))
      v=trim(substr(line, pos+1))
      if (k == want) {
        if (v ~ /^".*"$/) {
          sub(/^"/, "", v)
          sub(/"$/, "", v)
          gsub(/\\"/, "\"", v)
          gsub(/\\\\/, "\\", v)
        }
        print v
        exit
      }
    }
  ' <<< "$payload"
}

read_toml_value() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  awk -v want="$key" '
    function trim(s) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      return s
    }
    {
      line=$0
      pos=index(line, "=")
      if (pos == 0) next
      k=trim(substr(line, 1, pos-1))
      v=trim(substr(line, pos+1))
      if (k == want) {
        if (v ~ /^".*"$/) {
          sub(/^"/, "", v)
          sub(/"$/, "", v)
        }
        print v
        exit
      }
    }
  ' "$file"
}

write_token_file() {
  local file="$1" token="$2" dir
  dir="${file%/*}"
  mkdir -p "$dir"
  printf '%s\n' "$token" > "$file"
  chown root:"$FRP_USER" "$file" 2>/dev/null || chown root:root "$file" 2>/dev/null || true
  chmod 640 "$file" 2>/dev/null || true
}

print_banner() {
  clear 2>/dev/null || true
  printf '%sfrp 管理脚本%s %s%s%s\n' "$C_BOLD$C_CYAN" "$C_RESET" "$C_DIM" "$SCRIPT_VERSION" "$C_RESET"
  ui_rule
  render_status_bar
  echo
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

fetch_latest_version_tag() {
  load_installer_config
  local tag json api_url
  api_url="$(apply_github_proxy "$GH_API")"
  json="$(curl -fsSL --connect-timeout 15 --retry 2 --retry-delay 1 "$api_url" 2>/dev/null || true)"
  if [[ -z "$json" && -n "${GH_PROXY:-}" ]]; then
    warn "通过 GitHub 代理获取 latest 失败，尝试直连 api.github.com。"
    json="$(curl -fsSL --connect-timeout 15 --retry 2 --retry-delay 1 "$GH_API" 2>/dev/null || true)"
  fi
  tag="$(printf '%s' "$json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\(v[0-9][^"]*\)".*/\1/p' | head -n1)"
  [[ -n "$tag" ]] || return 1
  printf '%s' "$tag"
}

get_latest_version() {
  local tag
  tag="$(fetch_latest_version_tag || true)"
  [[ -n "$tag" ]] || fatal "获取 frp 最新版本失败，可以手动输入版本，例如 v0.68.1，或先配置 GitHub 代理。"
  printf '%s' "$tag"
}

normalize_version_tag() {
  local text="${1:-}" version
  version="$(printf '%s' "$text" | grep -Eo 'v?[0-9]+([.][0-9]+){1,3}([-+._A-Za-z0-9]*)?' | head -n1 || true)"
  [[ -n "$version" ]] || return 1
  [[ "$version" =~ ^v ]] || version="v${version}"
  printf '%s' "$version"
}

resolve_default_version() {
  local explicit="${1:-}" installed="${2:-}" latest="${3:-}" default_version
  if [[ -n "$explicit" ]]; then
    default_version="$explicit"
  elif [[ -n "$latest" ]]; then
    default_version="$latest"
  else
    default_version="$installed"
  fi
  [[ -n "$default_version" ]] || return 1
  normalize_version_tag "$default_version"
}

select_version() {
  local default_version version installed_version latest_version
  installed_version="$(installed_frp_version)"
  if [[ -n "$installed_version" ]]; then
    info "检测到本机已安装 frp：${installed_version}"
  fi

  if [[ -z "${VERSION:-}" ]]; then
    info "正在获取 frp 最新版本..."
    latest_version="$(fetch_latest_version_tag || true)"
    if [[ -z "$latest_version" && -n "$installed_version" ]]; then
      warn "获取最新版本失败，将默认使用本机已安装版本 ${installed_version}。"
    elif [[ -z "$latest_version" ]]; then
      fatal "获取 frp 最新版本失败，可以手动输入 VERSION=v0.68.1，或先配置 GitHub 代理。"
    fi
  fi

  default_version="$(resolve_default_version "${VERSION:-}" "$installed_version" "$latest_version")"
  version="$(ask "请输入 frp 版本，保留默认；当前已安装 ${installed_version:-无}" "$default_version")"
  [[ "$version" =~ ^v ]] || version="v${version}"
  printf '%s' "$version"
}

binary_version_tag() {
  local bin="$1" text
  [[ -x "$bin" ]] || return 1
  text="$(frp_version_text "$bin")"
  normalize_version_tag "$text"
}

installed_frp_version() {
  local frps_version="" frpc_version=""
  frps_version="$(binary_version_tag "${INSTALL_DIR}/frps" 2>/dev/null || true)"
  frpc_version="$(binary_version_tag "${INSTALL_DIR}/frpc" 2>/dev/null || true)"

  if [[ -n "$frps_version" && "$frps_version" == "$frpc_version" ]]; then
    printf '%s' "$frps_version"
  elif [[ -n "$frps_version" && -n "$frpc_version" ]]; then
    printf 'frps %s / frpc %s' "$frps_version" "$frpc_version"
  else
    printf '%s' "${frps_version:-$frpc_version}"
  fi
}

should_skip_frp_download() {
  local target_version="$1" reinstall_answer="${2:-}" frps_version="" frpc_version="" installed_version
  target_version="$(normalize_version_tag "$target_version")"
  frps_version="$(binary_version_tag "${INSTALL_DIR}/frps" 2>/dev/null || true)"
  frpc_version="$(binary_version_tag "${INSTALL_DIR}/frpc" 2>/dev/null || true)"
  [[ -n "$frps_version" && -n "$frpc_version" ]] || return 1
  [[ "$frps_version" == "$frpc_version" && "$frps_version" == "$target_version" ]] || return 1
  installed_version="$frps_version"

  if [[ -n "$reinstall_answer" ]]; then
    [[ "$reinstall_answer" =~ ^[Nn]$ ]]
    return
  fi

  warn "检测到本机已安装 frp ${installed_version}，与目标版本相同。"
  if confirm "是否仍然重新下载并覆盖安装" "n"; then
    return 1
  fi
  ok "已跳过二进制下载，继续使用本机 frp ${installed_version}。"
  return 0
}

create_dirs_and_user() {
  mkdir -p "$CONFIG_DIR" "$FRPC_CONF_DIR" "$FRPC_CLIENTS_DIR" "$PRESET_DIR" "$LOG_DIR"

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
    chmod 750 "$CONFIG_DIR" "$FRPC_CONF_DIR" "$FRPC_CLIENTS_DIR" "$PRESET_DIR"
  else
    warn "无法创建系统用户 $FRP_USER，将使用 root 运行 systemd 服务。"
  fi
}

download_and_install_frp() {
  load_installer_config
  local version="$1" arch url direct_url tmpdir archive dirname
  arch="$(detect_arch)"
  archive="frp_${version#v}_linux_${arch}.tar.gz"
  direct_url="${GH_RELEASE_BASE}/${version}/${archive}"
  url="$(apply_github_proxy "$direct_url")"

  tmpdir="$(mktemp -d)"
  info "下载 frp ${version} (${arch})..."
  if ! curl_download "${tmpdir}/${archive}" "$url"; then
    if [[ -n "${GH_PROXY:-}" ]]; then
      warn "通过 GitHub 代理下载失败，尝试直连 GitHub。"
      curl_download "${tmpdir}/${archive}" "$direct_url"
    else
      return 1
    fi
  fi
  tar -xzf "${tmpdir}/${archive}" -C "$tmpdir"
  dirname="${tmpdir}/frp_${version#v}_linux_${arch}"
  [[ -x "${dirname}/frps" && -x "${dirname}/frpc" ]] || fatal "压缩包中没有找到 frps/frpc。"

  install -m 0755 "${dirname}/frps" "${INSTALL_DIR}/frps"
  install -m 0755 "${dirname}/frpc" "${INSTALL_DIR}/frpc"
  rm -rf "$tmpdir"

  ok "frp ${version} 已安装到 ${INSTALL_DIR}"
  printf "frps: %s\n" "$(frp_version_text "${INSTALL_DIR}/frps")"
}

curl_download() {
  local output="$1" url="$2"
  curl -fsSL --connect-timeout 15 --retry 3 --retry-delay 2 -o "$output" "$url"
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
  write_token_file "$TOKEN_FILE" "$token"
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

  if has_cmd systemctl; then
    systemctl daemon-reload || warn "systemctl daemon-reload 失败，请手动执行后再管理服务。"
  else
    warn "当前系统没有 systemctl，已写入服务文件但不能自动重载。"
  fi
  ok "已写入 /etc/systemd/system/${name}.service"
}

systemctl_enable_restart() {
  local service="$1" failed=0
  service_action "$service" enable "false"
  (( SERVICE_ACTION_STATUS == 0 )) || failed=1
  service_action "$service" restart "false"
  (( SERVICE_ACTION_STATUS == 0 )) || failed=1
  if (( failed == 0 )) && ! systemctl is-active --quiet "$service" >/dev/null 2>&1; then
    failed=1
    warn "${service} 未处于 active 状态，请查看日志。"
  fi
  if (( failed == 0 )); then
    ok "${service} 已启动并设置开机自启。"
  else
    warn "${service} 启动或自启设置失败，请查看日志。"
  fi
  SERVICE_ACTION_STATUS="$failed"
  print_service_summary "$service"
}

print_service_summary() {
  local service="$1" active enabled since
  if ! has_cmd systemctl; then
    warn "当前系统没有 systemctl，无法读取服务状态。"
    return 0
  fi
  if ! service_exists "$service"; then
    printf '服务：%s  状态：未安装\n' "$service"
    return 0
  fi
  active="$(systemctl is-active "$service" 2>/dev/null || true)"
  enabled="$(systemctl is-enabled "$service" 2>/dev/null || true)"
  since="$(systemctl show "$service" -p ActiveEnterTimestamp --value 2>/dev/null || true)"
  [[ -n "$active" ]] || active="unknown"
  [[ -n "$enabled" ]] || enabled="unknown"
  printf '服务：%s  状态：%s  自启：%s' "$service" "$active" "$enabled"
  [[ -n "$since" ]] && printf '  启动时间：%s' "$since"
  printf '\n'
}

service_exists() {
  local service="$1" template
  has_cmd systemctl || return 1
  systemctl list-unit-files "${service}.service" >/dev/null 2>&1 && return 0
  if [[ "$service" == frpc@* && "$service" != frpc@ ]]; then
    template="frpc@"
    systemctl list-unit-files "${template}.service" >/dev/null 2>&1
    return
  fi
  return 1
}

service_action() {
  local service="$1" action="${2:-status}" show_summary="${3:-true}"
  SERVICE_ACTION_STATUS=0
  if ! has_cmd systemctl; then
    SERVICE_ACTION_STATUS=1
    warn "当前系统没有 systemctl，无法管理 ${service}。"
    return 0
  fi

  case "$action" in
    status|logs) ;;
    start|stop|restart|enable|disable)
      if ! service_exists "$service"; then
        SERVICE_ACTION_STATUS=1
        warn "未找到 ${service}.service；请先安装/写入服务。"
        return 0
      fi
      ;;
    *) fatal "未知服务操作：$action" ;;
  esac

  case "$action" in
    status) print_service_summary "$service" ;;
    start|stop|restart)
      if ! systemctl "$action" "$service"; then
        SERVICE_ACTION_STATUS=1
        warn "${service} ${action} 执行失败。"
      fi
      ;;
    enable|disable)
      if ! systemctl "$action" "$service" >/dev/null; then
        SERVICE_ACTION_STATUS=1
        warn "${service} ${action} 执行失败。"
      fi
      ;;
    logs)
      if has_cmd journalctl; then
        journalctl -u "$service" -n 100 -f
      else
        warn "当前系统没有 journalctl。"
      fi
      ;;
  esac

  case "$action" in
    start|stop|restart|enable|disable)
      if [[ "$show_summary" == "true" ]]; then
        print_service_summary "$service"
      fi
      ;;
  esac
}

restart_service_if_present() {
  local service="$1" prompt default
  prompt="${2:-是否重启 ${service} 使配置生效}"
  default="${3:-Y}"
  if ! has_cmd systemctl; then
    warn "当前系统没有 systemctl，无法重启 ${service}。"
    return 0
  fi
  if ! service_exists "$service"; then
    warn "未找到 ${service}.service；配置已写入，安装服务后再启动。"
    return 0
  fi
  if confirm "$prompt" "$default"; then
    service_action "$service" restart "false"
    if (( SERVICE_ACTION_STATUS == 0 )); then
      ok "${service} 已重启。"
    else
      warn "${service} 重启失败，请查看日志。"
    fi
    print_service_summary "$service"
  else
    warn "未重启 ${service}，新配置要等下次启动后生效。"
  fi
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
  if [[ ! -x "$bin" ]]; then
    warn "无法校验配置：frp 可执行文件不存在或不可执行：$bin"
    return 1
  fi
  if [[ ! -f "$conf" ]]; then
    warn "无法校验配置：配置文件不存在：$conf"
    return 1
  fi
  info "校验配置：$bin verify -c $conf"
  "$bin" verify -c "$conf"
}

verify_config_interactive() {
  verify_config "$@" || true
}

verify_config_before_restart() {
  local status
  verify_config "$@" && return 0
  status=$?
  warn "配置校验失败，请先修复配置，已跳过自动重启：$2"
  return "$status"
}

frp_version_text() {
  local bin="$1" out=""
  [[ -x "$bin" ]] || return 0
  out="$("$bin" version 2>/dev/null || true)"
  [[ -n "$out" ]] || out="$("$bin" -v 2>/dev/null || true)"
  [[ -n "$out" ]] || out="$("$bin" --version 2>/dev/null || true)"
  printf '%s' "$out"
}

service_status_label() {
  local service="$1" active="" enabled=""
  has_cmd systemctl || { printf '服务状态未知'; return 0; }
  if ! service_exists "$service"; then
    printf '未装服务'
    return 0
  fi
  active="$(systemctl is-active "$service" 2>/dev/null || true)"
  enabled="$(systemctl is-enabled "$service" 2>/dev/null || true)"
  [[ -n "$active" ]] || active="unknown"
  [[ -n "$enabled" ]] || enabled="unknown"
  case "$active" in
    active) active="运行" ;;
    inactive) active="停止" ;;
    failed) active="失败" ;;
    *) active="未知" ;;
  esac
  case "$enabled" in
    enabled) enabled="自启" ;;
    disabled) enabled="未自启" ;;
    static) enabled="静态" ;;
    *) enabled="未知" ;;
  esac
  printf '%s/%s' "$active" "$enabled"
}

config_status_label() {
  local conf="$1"
  if [[ -s "$conf" ]]; then
    printf '已配置'
  elif [[ -f "$conf" ]]; then
    printf '空配置'
  else
    printf '未配置'
  fi
}

render_component_status() {
  local name="$1" bin="$2" conf="$3" service="$4" version config_state service_state
  version="$(binary_version_tag "$bin" 2>/dev/null || true)"
  [[ -n "$version" ]] || version="未安装"
  config_state="$(config_status_label "$conf")"
  service_state="$(service_status_label "$service")"
  printf '%s%s:%s %s / %s / %s\n' \
    "$C_BOLD" "$name" "$C_RESET" \
    "$(ui_state "$version")" \
    "$(ui_state "$config_state")" \
    "$(ui_service_state "$service_state")"
}

service_brief_label() {
  local service="$1" active=""
  if ! service_exists "$service"; then
    printf '未运行'
    return 0
  fi
  active="$(systemctl is-active "$service" 2>/dev/null || true)"
  case "$active" in
    active) printf '运行中' ;;
    failed) printf '异常' ;;
    *) printf '未运行' ;;
  esac
}

frpc_client_status_counts() {
  local instances=() name service active total=0 running=0 failed=0
  if [[ -f "$FRPC_CONFIG" ]]; then
    total=$((total + 1))
    if has_cmd systemctl && service_exists frpc; then
      active="$(systemctl is-active frpc 2>/dev/null || true)"
      case "$active" in
        active) running=$((running + 1)) ;;
        failed) failed=$((failed + 1)) ;;
      esac
    fi
  fi
  mapfile -t instances < <(list_frpc_instances)
  if has_cmd systemctl; then
    for name in "${instances[@]}"; do
      total=$((total + 1))
      service="$(instance_service_name "$name")" || continue
      service_exists "$service" || continue
      active="$(systemctl is-active "$service" 2>/dev/null || true)"
      case "$active" in
        active) running=$((running + 1)) ;;
        failed) failed=$((failed + 1)) ;;
      esac
    done
  else
    total=$((total + ${#instances[@]}))
  fi
  printf '%s %s %s\n' "$total" "$running" "$failed"
}

ui_client_count_state() {
  local total="$1" running="$2" failed="$3" label color="$C_DIM"
  label="${total}个/运行${running}"
  (( failed > 0 )) && label="${label}/异常${failed}"
  if (( failed > 0 )); then
    color="$C_RED"
  elif (( running > 0 )); then
    color="$C_GREEN"
  elif (( total > 0 )); then
    color="$C_YELLOW"
  fi
  printf '%s%s%s' "$color" "$label" "$C_RESET"
}

render_status_bar() {
  local client_count client_running client_failed
  IFS=' ' read -r client_count client_running client_failed < <(frpc_client_status_counts)
  client_count="${client_count:-0}"
  client_running="${client_running:-0}"
  client_failed="${client_failed:-0}"
  printf '%s状态：%s 服务端:%s | 客户端:%s\n' \
    "$C_BOLD" "$C_RESET" \
    "$(ui_state "$(service_brief_label frps)")" \
    "$(ui_client_count_state "$client_count" "$client_running" "$client_failed")"
}

validate_instance_name() {
  local name="${1:-}"
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] || return 1
  [[ "$name" != "." && "$name" != ".." ]]
}

instance_dir() {
  local name="$1"
  validate_instance_name "$name" || return 1
  printf '%s/%s' "$FRPC_CLIENTS_DIR" "$name"
}

instance_frpc_config() {
  printf '%s/frpc.toml' "$(instance_dir "$1")"
}

instance_frpc_conf_dir() {
  printf '%s/frpc.d' "$(instance_dir "$1")"
}

instance_token_file() {
  printf '%s/token' "$(instance_dir "$1")"
}

instance_log_file() {
  local name="$1"
  validate_instance_name "$name" || return 1
  printf '%s/frpc-%s.log' "$LOG_DIR" "$name"
}

instance_service_name() {
  local name="$1"
  validate_instance_name "$name" || return 1
  printf 'frpc@%s' "$name"
}

write_frpc_base_config() {
  local config="$1" split_dir="$2" token_file="$3" log_file="$4"
  local server_addr="$5" server_port="$6" user_name="$7" proto="$8"
  local tls_enable="$9" pool_count="${10}" dns_server="${11}"
  local admin_addr="${12}" admin_port="${13}" admin_user="${14}" admin_pass="${15}"
  local store_path="${16}" enable_store="${17}" config_dir

  config_dir="${config%/*}"
  mkdir -p "$config_dir" "$split_dir" "${log_file%/*}"

  cat > "$config" <<EOF_FRPC_BASE
# Generated by frp manager ${SCRIPT_VERSION}
serverAddr = "$(toml_escape "$server_addr")"
serverPort = ${server_port}
loginFailExit = true
includes = ["$(toml_escape "$split_dir")/*.toml"]

# Token authentication. The token is stored outside this config file.
auth.method = "token"
auth.tokenSource.type = "file"
auth.tokenSource.file.path = "$(toml_escape "$token_file")"

# Transport.
transport.protocol = "$(toml_escape "$proto")"
transport.tls.enable = ${tls_enable}
transport.poolCount = ${pool_count}

# Logs.
log.to = "$(toml_escape "$log_file")"
log.level = "info"
log.maxDays = 7
log.disablePrintColor = true
EOF_FRPC_BASE

  [[ -n "$user_name" ]] && echo "user = \"$(toml_escape "$user_name")\"" >> "$config"
  [[ -n "$dns_server" ]] && echo "dnsServer = \"$(toml_escape "$dns_server")\"" >> "$config"

  if [[ -n "$admin_addr" && -n "$admin_port" ]]; then
    cat >> "$config" <<EOF_FRPC_ADMIN

# Admin UI / runtime proxy management.
webServer.addr = "$(toml_escape "$admin_addr")"
webServer.port = ${admin_port}
webServer.user = "$(toml_escape "$admin_user")"
webServer.password = "$(toml_escape "$admin_pass")"
EOF_FRPC_ADMIN
    if [[ "$enable_store" == "true" ]]; then
      cat >> "$config" <<EOF_FRPC_STORE

[store]
path = "$(toml_escape "$store_path")"
EOF_FRPC_STORE
    fi
  fi

  chown root:"$FRP_USER" "$config" 2>/dev/null || true
  chmod 640 "$config" 2>/dev/null || true
}

render_frpc_pairing_payload() {
  local server_addr="$1" server_port="$2" token="$3" proto="$4"
  local tls_enable="$5" pool_count="$6" dns_server="$7" user_name="$8"
  cat <<EOF_FRPC_PAIRING
format = "install-frp-frpc-v1"
serverAddr = "$(toml_escape "$server_addr")"
serverPort = ${server_port}
token = "$(toml_escape "$token")"
transportProtocol = "$(toml_escape "$proto")"
tlsEnable = ${tls_enable}
poolCount = ${pool_count}
dnsServer = "$(toml_escape "$dns_server")"
userName = "$(toml_escape "$user_name")"
EOF_FRPC_PAIRING
}

write_frpc_config_from_pairing_payload() {
  local config="$1" split_dir="$2" token_file="$3" log_file="$4" store_file="$5" payload="$6"
  local format server_addr server_port token proto tls_enable pool_count dns_server user_name
  format="$(parse_payload_value "$payload" format)"
  [[ "$format" == "install-frp-frpc-v1" ]] || fatal "frps 配对码内容格式不正确。"
  server_addr="$(parse_payload_value "$payload" serverAddr)"
  server_port="$(parse_payload_value "$payload" serverPort)"
  token="$(parse_payload_value "$payload" token)"
  proto="$(parse_payload_value "$payload" transportProtocol)"
  tls_enable="$(parse_payload_value "$payload" tlsEnable)"
  pool_count="$(parse_payload_value "$payload" poolCount)"
  dns_server="$(parse_payload_value "$payload" dnsServer)"
  user_name="$(parse_payload_value "$payload" userName)"
  [[ -n "$server_addr" && -n "$server_port" && -n "$token" ]] || fatal "frps 配对码缺少 serverAddr/serverPort/token。"
  [[ -n "$proto" ]] || proto="tcp"
  [[ -n "$tls_enable" ]] || tls_enable="true"
  [[ -n "$pool_count" ]] || pool_count="0"

  write_token_file "$token_file" "$token"
  write_frpc_base_config \
    "$config" \
    "$split_dir" \
    "$token_file" \
    "$log_file" \
    "$server_addr" \
    "$server_port" \
    "$user_name" \
    "$proto" \
    "$tls_enable" \
    "$pool_count" \
    "$dns_server" \
    "" \
    "" \
    "" \
    "" \
    "$store_file" \
    "false"
}

list_frpc_instances() {
  local files=() file name
  [[ -d "$FRPC_CLIENTS_DIR" ]] || return 0
  mapfile -d '' -t files < <(find "$FRPC_CLIENTS_DIR" -mindepth 2 -maxdepth 2 -type f -name frpc.toml -print0 2>/dev/null | sort -z)
  for file in "${files[@]}"; do
    name="$(basename "$(dirname "$file")")"
    validate_instance_name "$name" || continue
    printf '%s\n' "$name"
  done
}

render_no_frpc_instances_hint() {
  printf '没有命名 frpc 实例。\n'
  printf '下一步：客户端 -> 实例 -> 新建/重配实例，或 客户端 -> 接入码 导入为 instance:<name>。\n'
}

render_frpc_instance_list() {
  local instances=() name service config split_dir
  mapfile -t instances < <(list_frpc_instances)
  if (( ${#instances[@]} == 0 )); then
    render_no_frpc_instances_hint
    return 0
  fi

  printf '命名 frpc 实例：\n'
  for name in "${instances[@]}"; do
    service="$(instance_service_name "$name")"
    config="$(instance_frpc_config "$name")"
    split_dir="$(instance_frpc_conf_dir "$name")"
    printf -- '- %s  %s  %s\n' "$name" "$service" "$(ui_service_state "$(service_status_label "$service")")"
    printf '  主配置：%s\n' "$config"
    printf '  拆分目录：%s\n' "$split_dir"
  done
}

render_frpc_template_service() {
  local user_line="" group_line="" cap_line
  if id "$FRP_USER" >/dev/null 2>&1; then
    user_line="User=${FRP_USER}"
    group_line="Group=${FRP_USER}"
  fi
  cap_line=$'AmbientCapabilities=CAP_NET_BIND_SERVICE\nCapabilityBoundingSet=CAP_NET_BIND_SERVICE'

  cat <<EOF_SERVICE
[Unit]
Description=frp client instance %i service
Documentation=https://gofrp.org/zh-cn/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
${user_line}
${group_line}
ExecStart=${INSTALL_DIR}/frpc -c ${FRPC_CLIENTS_DIR}/%i/frpc.toml
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
${cap_line}
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${FRPC_CLIENTS_DIR}/%i ${LOG_DIR}

[Install]
WantedBy=multi-user.target
EOF_SERVICE
}

write_frpc_template_service() {
  render_frpc_template_service > /etc/systemd/system/frpc@.service
  if has_cmd systemctl; then
    systemctl daemon-reload || warn "systemctl daemon-reload 失败，请手动执行后再管理 frpc@ 实例。"
  else
    warn "当前系统没有 systemctl，已写入 frpc@ 模板但不能自动重载。"
  fi
  ok "已写入 /etc/systemd/system/frpc@.service"
}

configure_named_frpc_instance() {
  create_dirs_and_user
  local name dir config split_dir token_file log_file store_file
  local server_addr server_port token user_name proto tls_enable pool_count dns_server
  local enable_admin admin_addr admin_port admin_user admin_pass enable_store service

  echo
  info "配置命名 frpc 客户端实例"
  while true; do
    name="$(ask_required "实例名，只能使用字母数字点号下划线短横线，例如 home" "")"
    if validate_instance_name "$name"; then
      break
    fi
    warn "实例名不合法，请使用 1-63 位字母、数字、点号、下划线或短横线，且以字母或数字开头。"
  done

  dir="$(instance_dir "$name")"
  config="$(instance_frpc_config "$name")"
  split_dir="$(instance_frpc_conf_dir "$name")"
  token_file="$(instance_token_file "$name")"
  log_file="$(instance_log_file "$name")"
  store_file="${dir}/frpc-store.json"
  mkdir -p "$dir" "$split_dir"

  server_addr="$(ask_required "frps 服务器地址 serverAddr/IP/域名" "")"
  server_port="$(ask_port "frps 服务器端口 serverPort" "7000")"
  token="$(ask "鉴权 token，留空自动生成/沿用 ${token_file}" "")"
  if [[ -z "$token" && -s "$token_file" ]]; then
    token="$(tr -d '[:space:]' < "$token_file")"
  fi
  [[ -z "$token" ]] && token="$(random_secret)"
  write_token_file "$token_file" "$token"
  user_name="$(ask "客户端 user，留空不设置；多人共用服务端建议填写" "")"

  echo "通信协议可选：tcp / kcp / quic / websocket / wss"
  proto="$(ask "transport.protocol" "tcp")"
  case "$proto" in tcp|kcp|quic|websocket|wss) ;; *) warn "未知协议，回退 tcp"; proto="tcp" ;; esac
  tls_enable="$(ask_yes_no_value "是否启用 frpc->frps TLS；新版默认启用，建议保留" "Y")"
  pool_count="$(ask "连接池数量 transport.poolCount，普通场景 0，短连接高并发可 1-5" "0")"
  [[ "$pool_count" =~ ^[0-9]+$ ]] || pool_count=0
  dns_server="$(ask "自定义 DNS 服务器，留空使用系统 DNS，例如 1.1.1.1" "")"

  enable_admin="$(ask_yes_no_value "是否启用该实例的 Admin UI / 动态代理管理" "n")"
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

  if [[ -f "$config" ]]; then
    cp -a "$config" "${config}.bak.$(date +%Y%m%d-%H%M%S)"
  fi

  write_frpc_base_config \
    "$config" \
    "$split_dir" \
    "$token_file" \
    "$log_file" \
    "$server_addr" \
    "$server_port" \
    "$user_name" \
    "$proto" \
    "$tls_enable" \
    "$pool_count" \
    "$dns_server" \
    "$admin_addr" \
    "$admin_port" \
    "$admin_user" \
    "$admin_pass" \
    "$store_file" \
    "$enable_store"

  verify_config_before_restart "${INSTALL_DIR}/frpc" "$config" || return 0
  write_frpc_template_service
  service="$(instance_service_name "$name")"
  if confirm "是否现在启动/重启 ${service}" "Y"; then
    systemctl_enable_restart "$service"
  fi

  echo
  ok "frpc 实例 ${name} 配置完成：$config"
  echo "代理拆分配置目录：$split_dir"
}

rewrite_frpc_config_for_instance() {
  local config="$1" split_dir="$2" token_file="$3" log_file="$4" store_file="$5" tmp
  tmp="$(mktemp)"
  awk \
    -v includes_line="includes = [\"$(toml_escape "$split_dir")/*.toml\"]" \
    -v token_line="auth.tokenSource.file.path = \"$(toml_escape "$token_file")\"" \
    -v log_line="log.to = \"$(toml_escape "$log_file")\"" \
    -v store_line="path = \"$(toml_escape "$store_file")\"" \
    -v store_dotted_line="store.path = \"$(toml_escape "$store_file")\"" '
    function trim(s) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      return s
    }
    function key_of(line,    pos) {
      pos = index(line, "=")
      if (pos == 0) return ""
      return trim(substr(line, 1, pos - 1))
    }
    function emit_missing_top() {
      if (top_done) return
      if (!includes_done) print includes_line
      if (!token_done) print token_line
      if (!log_done) print log_line
      top_done = 1
    }
    function flush_store_path() {
      if (section == "store" && !store_done) {
        print store_line
        store_done = 1
      }
    }
    /^[[:space:]]*\[/ {
      emit_missing_top()
      flush_store_path()
      section = ""
      if ($0 ~ /^[[:space:]]*\[store\][[:space:]]*$/) {
        section = "store"
      }
      print
      next
    }
    {
      k = key_of($0)
      if (k == "includes") {
        print includes_line
        includes_done = 1
        next
      }
      if (k == "auth.tokenSource.file.path") {
        print token_line
        token_done = 1
        next
      }
      if (k == "log.to") {
        print log_line
        log_done = 1
        next
      }
      if (section == "store" && k == "path") {
        print store_line
        store_done = 1
        next
      }
      if (k == "store.path") {
        print store_dotted_line
        store_done = 1
        next
      }
      print
    }
    END {
      emit_missing_top()
      flush_store_path()
    }
  ' "$config" > "$tmp"
  mv "$tmp" "$config"
}

copy_default_frpc_to_instance() {
  create_dirs_and_user
  local name dir config split_dir token_file log_file store_file service copied=0 instance_started=0

  if [[ ! -f "$FRPC_CONFIG" ]]; then
    warn "默认 frpc 主配置不存在：$FRPC_CONFIG"
    warn "请先配置默认 frpc，或直接新建命名实例。"
    return 0
  fi

  while true; do
    name="$(ask_required "实例名，只能使用字母数字点号下划线短横线，例如 home" "")"
    if validate_instance_name "$name"; then
      break
    fi
    warn "实例名不合法，请使用 1-63 位字母、数字、点号、下划线或短横线，且以字母或数字开头。"
  done

  dir="$(instance_dir "$name")"
  config="$(instance_frpc_config "$name")"
  split_dir="$(instance_frpc_conf_dir "$name")"
  token_file="$(instance_token_file "$name")"
  log_file="$(instance_log_file "$name")"
  store_file="${dir}/frpc-store.json"
  service="$(instance_service_name "$name")"

  if [[ -e "$config" || -d "$split_dir" ]]; then
    if confirm "实例 ${name} 已存在，是否覆盖同名文件" "n"; then
      [[ -f "$config" ]] && backup_file "$config" >/dev/null || true
      [[ -f "$token_file" ]] && backup_file "$token_file" >/dev/null || true
      [[ -f "$store_file" ]] && backup_file "$store_file" >/dev/null || true
    else
      warn "已取消复制。"
      return 0
    fi
  fi

  mkdir -p "$dir" "$split_dir" "${log_file%/*}"
  cp -a "$FRPC_CONFIG" "$config"
  rewrite_frpc_config_for_instance "$config" "$split_dir" "$token_file" "$log_file" "$store_file"

  if [[ -f "$TOKEN_FILE" ]]; then
    cp -a "$TOKEN_FILE" "$token_file"
  else
    warn "默认 token 文件不存在：$TOKEN_FILE；如果配置使用 tokenSource，请手动补齐 ${token_file}。"
  fi

  if [[ -f "$FRPC_STORE" ]]; then
    cp -a "$FRPC_STORE" "$store_file"
  fi

  if [[ -d "$FRPC_CONF_DIR" ]]; then
    while IFS= read -r -d '' file; do
      cp -a "$file" "$split_dir/"
      copied=1
    done < <(find "$FRPC_CONF_DIR" -maxdepth 1 -type f -name '*.toml' -print0 2>/dev/null | sort -z)
  fi
  (( copied == 1 )) || warn "默认 frpc 拆分配置目录没有可复制的 TOML：${FRPC_CONF_DIR}/*.toml"

  chown -R root:"$FRP_USER" "$dir" 2>/dev/null || true
  chown "$FRP_USER":"$FRP_USER" "$log_file" 2>/dev/null || true
  chmod 750 "$dir" "$split_dir" 2>/dev/null || true
  chmod 640 "$config" "$token_file" "$store_file" 2>/dev/null || true

  verify_config_before_restart "${INSTALL_DIR}/frpc" "$config" || return 0
  write_frpc_template_service

  if confirm "是否现在启动/重启 ${service}" "Y"; then
    systemctl_enable_restart "$service"
    (( ${SERVICE_ACTION_STATUS:-1} == 0 )) && instance_started=1
  fi

  if service_exists frpc; then
    if (( instance_started == 1 )); then
      if confirm "是否停止并取消默认 frpc 自启，避免同一批代理重复连接" "n"; then
        service_action frpc stop "false"
        service_action frpc disable "false"
      fi
    else
      warn "实例 ${service} 未确认启动成功，已保留默认 frpc，避免断开现有连接。"
    fi
  fi

  ok "已从默认 frpc 复制为实例 ${name}：$config"
  echo "代理拆分配置目录：$split_dir"
}

# ---------- frps ----------
install_or_update_binaries() {
  install_dependencies
  create_dirs_and_user
  local version
  version="$(select_version)"
  if should_skip_frp_download "$version"; then
    return 0
  fi
  download_and_install_frp "$version"
}

configure_frps() {
  create_dirs_and_user
  local bind_addr bind_port token token_value enable_kcp enable_quic kcp_port quic_port
  local enable_http http_port enable_https https_port subdomain_host
  local enable_dashboard dash_addr dash_port dash_user dash_pass enable_prom max_pool quic_default

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
    quic_default="$bind_port"
    if [[ -n "$kcp_port" && "$kcp_port" == "$bind_port" ]]; then
      if (( bind_port < 65535 )); then quic_default=$((bind_port + 1)); else quic_default=$((bind_port - 1)); fi
    fi
    while true; do
      quic_port="$(ask_port "QUIC UDP 端口 quicBindPort；不能和 kcpBindPort 相同" "$quic_default")"
      [[ -z "$kcp_port" || "$quic_port" != "$kcp_port" ]] && break
      warn "quicBindPort 不能和 kcpBindPort 使用同一个 UDP 端口：$quic_port"
    done
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

  enable_dashboard="$(ask_yes_no_value "是否启用 frps Dashboard / Prometheus" "n")"
  if [[ "$enable_dashboard" == "true" ]]; then
    dash_addr="$(ask "Dashboard 监听地址，公网访问用 0.0.0.0，本机安全用 127.0.0.1" "127.0.0.1")"
    dash_port="$(ask_port "Dashboard 端口" "7500")"
    dash_user="$(ask "Dashboard 用户名" "admin")"
    dash_pass="$(ask "Dashboard 密码，留空随机生成" "")"
    [[ -z "$dash_pass" ]] && dash_pass="$(random_secret | cut -c1-16)"
    enable_prom="$(ask_yes_no_value "是否启用 Prometheus 指标" "n")"
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
log.disablePrintColor = true
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
  verify_config_before_restart "${INSTALL_DIR}/frps" "$FRPS_CONFIG" || return 0

  write_systemd_service "frps" "${INSTALL_DIR}/frps" "$FRPS_CONFIG"
  if confirm "是否现在启动/重启 frps" "Y"; then
    systemctl_enable_restart frps
  fi

  try_open_firewall_port "$bind_port" "tcp"
  [[ -n "$kcp_port" ]] && try_open_firewall_port "$kcp_port" "udp"
  [[ -n "$quic_port" ]] && try_open_firewall_port "$quic_port" "udp"
  [[ -n "$http_port" ]] && try_open_firewall_port "$http_port" "tcp"
  [[ -n "$https_port" ]] && try_open_firewall_port "$https_port" "tcp"
  [[ -n "$dash_port" && "$dash_addr" != "127.0.0.1" && "$dash_addr" != "localhost" ]] && try_open_firewall_port "$dash_port" "tcp"

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
  local server_addr server_port token user_name proto tls_enable pool_count dns_server
  local enable_admin admin_addr admin_port admin_user admin_pass enable_store

  echo
  info "配置 frpc 客户端"
  server_addr="$(ask_required "frps 服务器地址 serverAddr/IP/域名" "")"
  server_port="$(ask_port "frps 服务器端口 serverPort" "7000")"
  token="$(ask "鉴权 token，留空自动生成/沿用 ${TOKEN_FILE}" "")"
  ensure_token_file "$token"
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

  write_frpc_base_config \
    "$FRPC_CONFIG" \
    "$FRPC_CONF_DIR" \
    "$TOKEN_FILE" \
    "${LOG_DIR}/frpc.log" \
    "$server_addr" \
    "$server_port" \
    "$user_name" \
    "$proto" \
    "$tls_enable" \
    "$pool_count" \
    "$dns_server" \
    "$admin_addr" \
    "$admin_port" \
    "$admin_user" \
    "$admin_pass" \
    "$FRPC_STORE" \
    "$enable_store"

  chown root:"$FRP_USER" "$FRPC_CONFIG" 2>/dev/null || true
  chmod 640 "$FRPC_CONFIG"
  verify_config_before_restart "${INSTALL_DIR}/frpc" "$FRPC_CONFIG" || return 0

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
  local type="$1" name="$2" file="$3" server_name server_user secret bind_addr bind_port
  server_name="$(ask_required "要访问的服务端代理名 serverName" "")"
  server_user="$(ask "被访问端 frpc user serverUser，留空默认同当前 user" "")"
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
  [[ -n "$server_user" ]] && echo "serverUser = \"$(toml_escape "$server_user")\"" >> "$file"
}

render_xtcp_payload() {
  local server_addr="$1" server_port="$2" proxy_name="$3" visitor_name="$4" secret="$5"
  local bind_addr="$6" bind_port="$7" keep_tunnel_open="$8" fallback="$9"
  local fallback_proxy_name="${10}" fallback_visitor_name="${11}" fallback_timeout_ms="${12}"
  local protocol="${13:-quic}" disable_assisted_addrs="${14:-false}"
  local server_user="${15:-}" allow_users="${16:-}"
  cat <<EOF_XTCP_PAYLOAD
format = "install-frp-xtcp-v1"
serverAddr = "$(toml_escape "$server_addr")"
serverPort = ${server_port}
proxyName = "$(toml_escape "$proxy_name")"
visitorName = "$(toml_escape "$visitor_name")"
secretKey = "$(toml_escape "$secret")"
bindAddr = "$(toml_escape "$bind_addr")"
bindPort = ${bind_port}
protocol = "$(toml_escape "$protocol")"
keepTunnelOpen = ${keep_tunnel_open}
fallback = ${fallback}
fallbackProxyName = "$(toml_escape "$fallback_proxy_name")"
fallbackVisitorName = "$(toml_escape "$fallback_visitor_name")"
fallbackTimeoutMs = ${fallback_timeout_ms}
disableAssistedAddrs = ${disable_assisted_addrs}
serverUser = "$(toml_escape "$server_user")"
allowUsers = "$(toml_escape "$allow_users")"
EOF_XTCP_PAYLOAD
}

parse_xtcp_payload_value() {
  parse_payload_value "$1" "$2"
}

write_xtcp_exposed_config() {
  local file="$1" proxy_name="$2" secret="$3" local_ip="$4" local_port="$5"
  local fallback="${6:-false}" fallback_proxy_name="${7:-}" disable_assisted_addrs="${8:-false}"
  local allow_users="${9:-}"
  mkdir -p "${file%/*}"
  cat > "$file" <<EOF_XTCP_EXPOSED
[[proxies]]
name = "$(toml_escape "$proxy_name")"
type = "xtcp"
secretKey = "$(toml_escape "$secret")"
localIP = "$(toml_escape "$local_ip")"
localPort = ${local_port}
EOF_XTCP_EXPOSED
  [[ -n "$allow_users" ]] && echo "allowUsers = $(toml_array_from_csv "$allow_users")" >> "$file"

  if [[ "$disable_assisted_addrs" == "true" ]]; then
    cat >> "$file" <<EOF_XTCP_PROXY_NAT

[proxies.natTraversal]
disableAssistedAddrs = true
EOF_XTCP_PROXY_NAT
  fi

  if [[ "$fallback" == "true" ]]; then
    cat >> "$file" <<EOF_XTCP_STCP

[[proxies]]
name = "$(toml_escape "$fallback_proxy_name")"
type = "stcp"
secretKey = "$(toml_escape "$secret")"
localIP = "$(toml_escape "$local_ip")"
localPort = ${local_port}
EOF_XTCP_STCP
    [[ -n "$allow_users" ]] && echo "allowUsers = $(toml_array_from_csv "$allow_users")" >> "$file"
  fi
  chown root:"$FRP_USER" "$file" 2>/dev/null || true
  chmod 640 "$file" 2>/dev/null || true
}

write_xtcp_visitor_config_from_payload() {
  local file="$1" payload="$2"
  local format server_name visitor_name secret bind_addr bind_port keep_tunnel_open
  local fallback fallback_proxy_name fallback_visitor_name fallback_timeout_ms protocol disable_assisted_addrs server_user
  format="$(parse_xtcp_payload_value "$payload" format)"
  [[ "$format" == "install-frp-xtcp-v1" ]] || fatal "XTCP 导入码内容格式不正确。"
  server_name="$(parse_xtcp_payload_value "$payload" proxyName)"
  visitor_name="$(parse_xtcp_payload_value "$payload" visitorName)"
  secret="$(parse_xtcp_payload_value "$payload" secretKey)"
  bind_addr="$(parse_xtcp_payload_value "$payload" bindAddr)"
  bind_port="$(parse_xtcp_payload_value "$payload" bindPort)"
  protocol="$(parse_xtcp_payload_value "$payload" protocol)"
  keep_tunnel_open="$(parse_xtcp_payload_value "$payload" keepTunnelOpen)"
  fallback="$(parse_xtcp_payload_value "$payload" fallback)"
  fallback_proxy_name="$(parse_xtcp_payload_value "$payload" fallbackProxyName)"
  fallback_visitor_name="$(parse_xtcp_payload_value "$payload" fallbackVisitorName)"
  fallback_timeout_ms="$(parse_xtcp_payload_value "$payload" fallbackTimeoutMs)"
  disable_assisted_addrs="$(parse_xtcp_payload_value "$payload" disableAssistedAddrs)"
  server_user="$(parse_xtcp_payload_value "$payload" serverUser)"
  [[ -n "$protocol" ]] || protocol="quic"
  case "$protocol" in quic|kcp) ;; *) protocol="quic" ;; esac
  [[ -n "$disable_assisted_addrs" ]] || disable_assisted_addrs="false"

  mkdir -p "${file%/*}"
  : > "$file"
  if [[ "$fallback" == "true" ]]; then
    cat >> "$file" <<EOF_XTCP_STCP_VISITOR
[[visitors]]
name = "$(toml_escape "$fallback_visitor_name")"
type = "stcp"
serverName = "$(toml_escape "$fallback_proxy_name")"
secretKey = "$(toml_escape "$secret")"
bindPort = -1
EOF_XTCP_STCP_VISITOR
    [[ -n "$server_user" ]] && echo "serverUser = \"$(toml_escape "$server_user")\"" >> "$file"
    printf '\n' >> "$file"
  fi

  cat >> "$file" <<EOF_XTCP_VISITOR
[[visitors]]
name = "$(toml_escape "$visitor_name")"
type = "xtcp"
protocol = "$(toml_escape "$protocol")"
serverName = "$(toml_escape "$server_name")"
secretKey = "$(toml_escape "$secret")"
bindAddr = "$(toml_escape "$bind_addr")"
bindPort = ${bind_port}
keepTunnelOpen = ${keep_tunnel_open}
EOF_XTCP_VISITOR
  [[ -n "$server_user" ]] && echo "serverUser = \"$(toml_escape "$server_user")\"" >> "$file"

  if [[ "$fallback" == "true" ]]; then
    cat >> "$file" <<EOF_XTCP_FALLBACK
fallbackTo = "$(toml_escape "$fallback_visitor_name")"
fallbackTimeoutMs = ${fallback_timeout_ms}
EOF_XTCP_FALLBACK
  fi

  if [[ "$disable_assisted_addrs" == "true" ]]; then
    cat >> "$file" <<EOF_XTCP_NAT

[visitors.natTraversal]
disableAssistedAddrs = true
EOF_XTCP_NAT
  fi

  chown root:"$FRP_USER" "$file" 2>/dev/null || true
  chmod 640 "$file" 2>/dev/null || true
}

tune_xtcp_config_file() {
  local file="$1" protocol="${2:-quic}" disable_assisted_addrs="${3:-true}" fallback_timeout_ms="${4:-5000}" keep_tunnel_open="${5:-true}" tmp
  [[ -f "$file" ]] || fatal "配置文件不存在：$file"
  case "$protocol" in quic|kcp) ;; *) protocol="quic" ;; esac
  [[ "$fallback_timeout_ms" =~ ^[0-9]+$ ]] || fallback_timeout_ms=5000
  [[ "$disable_assisted_addrs" == "true" ]] || disable_assisted_addrs="false"
  [[ "$keep_tunnel_open" == "true" ]] || keep_tunnel_open="false"

  tmp="$(mktemp)"
  awk -v protocol="$protocol" -v disable="$disable_assisted_addrs" -v timeout="$fallback_timeout_ms" -v keep="$keep_tunnel_open" '
    function reset_block() {
      n = 0
      kind = ""
      is_xtcp = 0
    }
    function push(line) {
      lines[++n] = line
    }
    function flush_block(    i,line,skip_nat) {
      if (n == 0) return
      if (!is_xtcp) {
        for (i = 1; i <= n; i++) print lines[i]
        reset_block()
        return
      }
      skip_nat = 0
      for (i = 1; i <= n; i++) {
        line = lines[i]
        if (line ~ /^[[:space:]]*\[(visitors|proxies)\.natTraversal\][[:space:]]*$/) {
          skip_nat = 1
          continue
        }
        if (skip_nat && line ~ /^[[:space:]]*disableAssistedAddrs[[:space:]]*=/) {
          continue
        }
        if (skip_nat && line ~ /^[[:space:]]*\[/) {
          skip_nat = 0
        }
        if (kind == "visitors" && line ~ /^[[:space:]]*protocol[[:space:]]*=/) continue
        if (kind == "visitors" && line ~ /^[[:space:]]*keepTunnelOpen[[:space:]]*=/) continue
        if (kind == "visitors" && line ~ /^[[:space:]]*fallbackTimeoutMs[[:space:]]*=/) continue
        print line
        if (kind == "visitors" && line ~ /^[[:space:]]*type[[:space:]]*=[[:space:]]*"xtcp"/) {
          print "protocol = \"" protocol "\""
        }
        if (kind == "visitors" && line ~ /^[[:space:]]*bindPort[[:space:]]*=/) {
          print "keepTunnelOpen = " keep
        }
        if (kind == "visitors" && line ~ /^[[:space:]]*fallbackTo[[:space:]]*=/) {
          print "fallbackTimeoutMs = " timeout
        }
      }
      if (disable == "true") {
        print ""
        if (kind == "visitors") {
          print "[visitors.natTraversal]"
        } else if (kind == "proxies") {
          print "[proxies.natTraversal]"
        }
        print "disableAssistedAddrs = true"
      }
      reset_block()
    }
    BEGIN { reset_block() }
    /^[[:space:]]*\[\[visitors\]\][[:space:]]*$/ {
      flush_block()
      kind = "visitors"
      push($0)
      next
    }
    /^[[:space:]]*\[\[proxies\]\][[:space:]]*$/ {
      flush_block()
      kind = "proxies"
      push($0)
      next
    }
    {
      push($0)
      if (kind != "" && $0 ~ /^[[:space:]]*type[[:space:]]*=[[:space:]]*"xtcp"/) is_xtcp = 1
    }
    END { flush_block() }
  ' "$file" > "$tmp"
  cp "$tmp" "$file"
  rm -f "$tmp"
  chown root:"$FRP_USER" "$file" 2>/dev/null || true
  chmod 640 "$file" 2>/dev/null || true
}

render_xtcp_config_summary() {
  local file="${1:-}"
  [[ -f "$file" ]] || { warn "配置文件不存在：$file"; return 0; }
  awk '
    function trim(s) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      return s
    }
    function unquote(s) {
      s = trim(s)
      if (s ~ /^".*"$/) {
        sub(/^"/, "", s)
        sub(/"$/, "", s)
      }
      return s
    }
    function reset_block() {
      kind = ""
      name = ""
      type = ""
      protocol = ""
      keep = ""
      fallback_to = ""
      fallback_timeout = ""
      disable = ""
      in_nat = 0
    }
    function flush_block() {
      if (type != "xtcp") {
        reset_block()
        return
      }
      if (kind == "visitor") {
        printf "visitor %s protocol=%s keepTunnelOpen=%s fallbackTo=%s fallbackTimeoutMs=%s disableAssistedAddrs=%s\n", \
          name, (protocol ? protocol : "quic"), (keep ? keep : "false"), (fallback_to ? fallback_to : "-"), \
          (fallback_timeout ? fallback_timeout : "-"), (disable ? disable : "false")
      } else if (kind == "proxy") {
        printf "proxy %s disableAssistedAddrs=%s\n", name, (disable ? disable : "false")
      }
      reset_block()
    }
    BEGIN { reset_block() }
    /^[[:space:]]*\[\[visitors\]\][[:space:]]*$/ {
      flush_block()
      kind = "visitor"
      next
    }
    /^[[:space:]]*\[\[proxies\]\][[:space:]]*$/ {
      flush_block()
      kind = "proxy"
      next
    }
    /^[[:space:]]*\[(visitors|proxies)\.natTraversal\][[:space:]]*$/ {
      in_nat = 1
      next
    }
    /^[[:space:]]*\[/ {
      in_nat = 0
      next
    }
    {
      pos = index($0, "=")
      if (pos == 0) next
      k = trim(substr($0, 1, pos - 1))
      v = unquote(substr($0, pos + 1))
      if (in_nat && k == "disableAssistedAddrs") disable = v
      if (k == "name") name = v
      else if (k == "type") type = v
      else if (k == "protocol") protocol = v
      else if (k == "keepTunnelOpen") keep = v
      else if (k == "fallbackTo") fallback_to = v
      else if (k == "fallbackTimeoutMs") fallback_timeout = v
    }
    END { flush_block() }
  ' "$file"
}

xtcp_file_has_config() {
  local file="${1:-}" found
  [[ -f "$file" ]] || { printf 'false\n'; return 0; }
  found="$(awk '
    function flush_block() {
      if (in_block && is_xtcp) found = 1
      in_block = 0
      is_xtcp = 0
    }
    BEGIN {
      in_block = 0
      is_xtcp = 0
      found = 0
    }
    /^[[:space:]]*\[\[(visitors|proxies)\]\][[:space:]]*$/ {
      flush_block()
      in_block = 1
      next
    }
    /^[[:space:]]*\[\[/ {
      flush_block()
      next
    }
    {
      if (in_block && $0 ~ /^[[:space:]]*type[[:space:]]*=[[:space:]]*"xtcp"/) is_xtcp = 1
    }
    END {
      flush_block()
      print(found ? "true" : "false")
    }
  ' "$file")"
  printf '%s\n' "$found"
}

list_xtcp_config_files() {
  local path="${1:-}" files=() file
  [[ -n "$path" ]] || return 0
  if [[ -f "$path" ]]; then
    if [[ "$(xtcp_file_has_config "$path")" == "true" ]]; then
      printf '%s\n' "$path"
    fi
    return 0
  fi
  [[ -d "$path" ]] || return 0
  mapfile -d '' -t files < <(find "$path" -maxdepth 1 -type f -name '*.toml' -print0 2>/dev/null | sort -z)
  for file in "${files[@]}"; do
    if [[ "$(xtcp_file_has_config "$file")" == "true" ]]; then
      printf '%s\n' "$file"
    fi
  done
}

render_xtcp_path_summary() {
  local path="${1:-}" files=() file summary
  mapfile -t files < <(list_xtcp_config_files "$path")
  for file in "${files[@]}"; do
    printf '== %s ==\n' "$(basename "$file")"
    printf '路径：%s\n' "$file"
    summary="$(render_xtcp_config_summary "$file")"
    if [[ -n "$summary" ]]; then
      printf '%s\n' "$summary"
    else
      printf '未找到 XTCP 条目\n'
    fi
  done

  if (( ${#files[@]} == 0 )); then
    warn "未找到 XTCP 配置：$path"
  fi
}

repair_xtcp_path() {
  local path="${1:-}" protocol="${2:-quic}" disable_assisted_addrs="${3:-false}"
  local fallback_timeout_ms="${4:-5000}" keep_tunnel_open="${5:-true}"
  local files=() file backup
  mapfile -t files < <(list_xtcp_config_files "$path")

  if (( ${#files[@]} == 0 )); then
    fatal "未找到 XTCP 配置：$path"
  fi

  for file in "${files[@]}"; do
    backup="$(backup_file "$file" || true)"
    tune_xtcp_config_file "$file" "$protocol" "$disable_assisted_addrs" "$fallback_timeout_ms" "$keep_tunnel_open"
    if [[ -n "$backup" ]]; then
      printf '已修复：%s（备份：%s）\n' "$file" "$backup"
    else
      printf '已修复：%s\n' "$file"
    fi
  done
}

select_frpc_split_dir_for_write() {
  local target="${1:-}" strict="${2:-false}" name config
  if [[ -z "$target" ]]; then
    if [[ "$strict" == "true" && ! -t 0 ]]; then
      warn "非交互导入必须指定目标：default 或 instance:<name>。"
      return 1
    fi
    echo "写入目标：1) 默认 frpc  2) 命名 frpc 实例"
    target="$(ask "请选择" "1")"
  fi
  case "$target" in
    1|default|frpc)
      SELECTED_FRPC_LABEL="默认 frpc"
      SELECTED_FRPC_CONFIG="$FRPC_CONFIG"
      SELECTED_FRPC_SPLIT_DIR="$FRPC_CONF_DIR"
      SELECTED_FRPC_SERVICE="frpc"
      ;;
    2|instance)
      if [[ "$strict" == "true" ]]; then
        warn "非交互导入命名实例必须使用 instance:<name>。"
        return 1
      fi
      [[ -n "${name:-}" ]] || name="$(ask_required "实例名" "")"
      validate_instance_name "$name" || { warn "实例名不合法：$name"; return 1; }
      config="$(instance_frpc_config "$name")"
      if [[ ! -f "$config" ]]; then
        warn "命名 frpc 实例主配置不存在：$config"
        return 1
      fi
      SELECTED_FRPC_LABEL="实例 ${name}"
      SELECTED_FRPC_CONFIG="$config"
      SELECTED_FRPC_SPLIT_DIR="$(instance_frpc_conf_dir "$name")"
      SELECTED_FRPC_SERVICE="$(instance_service_name "$name")"
      ;;
    instance:*)
      name="${target#instance:}"
      validate_instance_name "$name" || { warn "实例名不合法：$name"; return 1; }
      config="$(instance_frpc_config "$name")"
      if [[ ! -f "$config" ]]; then
        warn "命名 frpc 实例主配置不存在：$config"
        return 1
      fi
      SELECTED_FRPC_LABEL="实例 ${name}"
      SELECTED_FRPC_CONFIG="$config"
      SELECTED_FRPC_SPLIT_DIR="$(instance_frpc_conf_dir "$name")"
      SELECTED_FRPC_SERVICE="$(instance_service_name "$name")"
      ;;
    *) warn "无效选择"; return 1 ;;
  esac
  mkdir -p "$SELECTED_FRPC_SPLIT_DIR"
}

with_frpc_write_target() {
  select_frpc_split_dir_for_write || return 0
  "$@"
}

create_xtcp_exposed_and_code() {
  create_dirs_and_user
  local server_addr server_port name secret local_ip local_port bind_addr bind_port keep_open fallback
  local fallback_proxy fallback_visitor timeout protocol disable_assisted server_user allow_users passphrase payload code safe_name file
  select_frpc_split_dir_for_write || return 0
  server_addr="$(ask_required "导入端连接的 frps 地址/IP/域名" "")"
  server_port="$(ask_port "导入端连接的 frps 端口" "7000")"
  name="$(ask_required "XTCP 代理名 proxyName" "p2p_ssh")"
  secret="$(ask "secretKey，留空随机生成" "")"
  [[ -z "$secret" ]] && secret="$(random_secret)"
  local_ip="$(ask "被访问本地服务 IP localIP" "127.0.0.1")"
  local_port="$(ask_port "被访问本地服务端口 localPort" "22")"
  bind_addr="$(ask "访问端本地监听地址 bindAddr" "127.0.0.1")"
  bind_port="$(ask_port "访问端本地监听端口 bindPort" "6000")"
  protocol="$(ask "访问端 XTCP 底层协议 quic/kcp" "quic")"
  case "$protocol" in quic|kcp) ;; *) warn "未知协议，回退 quic"; protocol="quic" ;; esac
  server_user="$(ask "被访问端 frpc user serverUser，留空默认同访问端 user" "")"
  allow_users="$(ask "allowUsers，留空默认只允许同 user；允许所有填 *" "")"
  disable_assisted="$(ask_yes_no_value "禁用辅助地址；有 Docker/VPN/100.64 地址干扰时建议启用" "n")"
  keep_open="$(ask_yes_no_value "访问端是否 keepTunnelOpen" "Y")"
  fallback="$(ask_yes_no_value "是否生成 STCP fallback" "Y")"
  fallback_proxy="${name}_stcp"
  fallback_visitor="${name}_stcp_fallback"
  timeout="$(ask "fallbackTimeoutMs；打洞常需 1-5 秒，太短会一直 fallback" "5000")"
  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=5000

  safe_name="$(safe_filename "$name")"
  file="${SELECTED_FRPC_SPLIT_DIR}/${safe_name}.toml"
  if [[ -f "$file" ]]; then
    if confirm "配置 ${file} 已存在，是否覆盖" "n"; then
      backup_file "$file" >/dev/null || true
    else
      warn "已取消覆盖：$file"
      return 0
    fi
  fi
  write_xtcp_exposed_config "$file" "$name" "$secret" "$local_ip" "$local_port" "$fallback" "$fallback_proxy" "$disable_assisted" "$allow_users"
  verify_config_before_restart "${INSTALL_DIR}/frpc" "$SELECTED_FRPC_CONFIG" || return 0

  payload="$(render_xtcp_payload "$server_addr" "$server_port" "$name" "${name}_visitor" "$secret" "$bind_addr" "$bind_port" "$keep_open" "$fallback" "$fallback_proxy" "$fallback_visitor" "$timeout" "$protocol" "$disable_assisted" "$server_user" "$allow_users")"
  passphrase="$(ask "导入码加密口令，留空随机生成" "")"
  [[ -z "$passphrase" ]] && passphrase="$(random_secret | cut -c1-20)"
  code="$(encrypt_payload_code "IFRP-XTCP-V1" "$passphrase" "$payload")"

  warn "下面的导入码和口令合在一起等同于 secretKey，请勿公开。"
  echo
  echo "========== XTCP 加密导入码 =========="
  echo "$code"
  echo "========== 解密码 =========="
  echo "$passphrase"
  echo "========== 一键导入命令（含解密码） =========="
  render_one_click_import_command "xtcp" "$code" "$passphrase"
  echo "===================================="
  restart_service_if_present "$SELECTED_FRPC_SERVICE"
}

import_xtcp_code_to_visitor() {
  create_dirs_and_user
  local code passphrase strict_verify target_spec payload visitor_name safe_name file verify_status
  code="${1:-}"
  passphrase="${2:-}"
  strict_verify="${3:-false}"
  target_spec="${4:-}"
  if ! select_frpc_split_dir_for_write "$target_spec" "$strict_verify"; then
    [[ "$strict_verify" == "true" ]] && return 1
    return 0
  fi
  if [[ -z "$code" ]]; then
    warn "请粘贴 XTCP 加密导入码，格式为 IFRP-XTCP-V1:..."
    code="$(ask_required "XTCP 导入码" "")"
  fi
  [[ -n "$passphrase" ]] || passphrase="$(ask_required "解密码" "")"
  if ! payload="$(decrypt_payload_code "IFRP-XTCP-V1" "$passphrase" "$code" 2>/dev/null)"; then
    warn "解密失败：XTCP 导入码或解密码不正确。"
    [[ "$strict_verify" == "true" ]] && return 1
    return 0
  fi
  visitor_name="$(parse_xtcp_payload_value "$payload" visitorName)"
  [[ -n "$visitor_name" ]] || fatal "导入码缺少 visitorName。"
  safe_name="$(safe_filename "$visitor_name")"
  file="${SELECTED_FRPC_SPLIT_DIR}/${safe_name}.toml"
  if [[ -f "$file" ]]; then
    if confirm "配置 ${file} 已存在，是否覆盖" "n"; then
      backup_file "$file" >/dev/null || true
    else
      warn "已取消覆盖：$file"
      [[ "$strict_verify" == "true" ]] && return 1
      return 0
    fi
  fi
  write_xtcp_visitor_config_from_payload "$file" "$payload"
  verify_status=0
  verify_config_before_restart "${INSTALL_DIR}/frpc" "$SELECTED_FRPC_CONFIG" || verify_status=$?
  if (( verify_status != 0 )); then
    [[ "$strict_verify" == "true" ]] && return "$verify_status"
    return 0
  fi
  restart_service_if_present "$SELECTED_FRPC_SERVICE"
  ok "已导入 XTCP 访问端配置：$file"
}

xtcp_config_check_menu() {
  create_dirs_and_user
  local protocol disable_assisted timeout
  select_frpc_split_dir_for_write || return 0
  if ! list_xtcp_config_files "$SELECTED_FRPC_SPLIT_DIR" | grep -q .; then
    warn "没有找到 XTCP 拆分配置：${SELECTED_FRPC_SPLIT_DIR}/*.toml"
    return 0
  fi

  echo
  info "当前 XTCP 配置摘要"
  render_xtcp_path_summary "$SELECTED_FRPC_SPLIT_DIR"

  protocol="$(ask "XTCP 底层协议 quic/kcp；官方默认 quic" "quic")"
  case "$protocol" in quic|kcp) ;; *) warn "未知协议，回退 quic"; protocol="quic" ;; esac
  disable_assisted="$(ask_yes_no_value "禁用辅助地址；日志里有 10.x/100.64/172.x 建议启用" "n")"
  timeout="$(ask "fallbackTimeoutMs" "5000")"
  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=5000

  if ! confirm "是否备份并修复以上 XTCP 配置" "Y"; then
    warn "已取消修复。"
    return 0
  fi

  repair_xtcp_path "$SELECTED_FRPC_SPLIT_DIR" "$protocol" "$disable_assisted" "$timeout" "true"
  verify_config_before_restart "${INSTALL_DIR}/frpc" "$SELECTED_FRPC_CONFIG" || return 0
  echo
  info "修复后 XTCP 配置摘要"
  render_xtcp_path_summary "$SELECTED_FRPC_SPLIT_DIR"
  restart_service_if_present "$SELECTED_FRPC_SERVICE"
  ok "XTCP 配置检查/修复完成。"
}

xtcp_pair_menu() {
  while true; do
    menu_title "客户端 / XTCP"
    ui_menu_item 1 "创建被访问端" "生成加密导入码"
    ui_menu_item 2 "导入访问端" "粘贴加密导入码"
    ui_menu_item 3 "检查/修复现有配置"
    ui_menu_back
    local choice
    choice="$(ask "请选择" "1")"
    case "$choice" in
      1) create_xtcp_exposed_and_code; pause ;;
      2) import_xtcp_code_to_visitor; pause ;;
      3) xtcp_config_check_menu; pause ;;
      0|q|Q) return 0 ;;
      *) warn "无效选择"; pause ;;
    esac
  done
}

safe_filename() {
  local name="$1"
  printf '%s' "$name" | sed 's/[^A-Za-z0-9._-]/_/g'
}

preset_meta_get() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  awk -v want="$key" '
    /^#/ {
      line=$0
      sub(/^#[[:space:]]*/, "", line)
      pos=index(line, "=")
      if (pos == 0) next
      k=substr(line, 1, pos-1)
      v=substr(line, pos+1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      if (k == want) {
        if (v ~ /^".*"$/) {
          sub(/^"/, "", v)
          sub(/"$/, "", v)
        }
        print v
        exit
      }
    }
  ' "$file"
}

extract_template_vars() {
  local file="$1" meta var
  meta="$(preset_meta_get "$file" "vars")"
  if [[ -n "$meta" ]]; then
    local oldifs="$IFS"
    IFS=',' read -r -a arr <<< "$meta"
    IFS="$oldifs"
    for var in "${arr[@]}"; do
      var="$(trim "$var")"
      [[ -n "$var" ]] && printf '%s\n' "$var"
    done
    return 0
  fi
  grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}|\{\{[A-Za-z_][A-Za-z0-9_]*\}\}' "$file" 2>/dev/null \
    | sed -E 's/^\$\{//; s/^\{\{//; s/\}$//; s/\}\}$//' \
    | awk '!seen[$0]++'
}

preset_list_files() {
  find "$PRESET_DIR" -maxdepth 1 -type f \( -name '*.tpl' -o -name '*.toml.tpl' -o -name '*.preset' \) 2>/dev/null | sort
}

choose_preset_file() {
  local files=() file idx choice title desc
  mapfile -t files < <(preset_list_files)
  if (( ${#files[@]} == 0 )); then
    warn "还没有自定义预设。请先在预设管理里创建，目录：$PRESET_DIR"
    return 1
  fi
  echo >&2
  info "自定义预设列表"
  idx=1
  for file in "${files[@]}"; do
    title="$(preset_meta_get "$file" "name")"
    desc="$(preset_meta_get "$file" "desc")"
    [[ -n "$title" ]] || title="$(basename "$file")"
    if [[ -n "$desc" ]]; then
      printf '%s) %s - %s\n' "$idx" "$title" "$desc" >&2
    else
      printf '%s) %s\n' "$idx" "$title" >&2
    fi
    idx=$((idx+1))
  done
  echo "0) 返回" >&2
  choice="$(ask "请选择预设" "1")"
  [[ "$choice" == "0" || "$choice" =~ ^[Qq]$ ]] && return 1
  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#files[@]} )); then
    SELECTED_PRESET_FILE="${files[$((choice-1))]}"
    return 0
  fi
  warn "无效选择。"
  return 1
}

write_rendered_frpc_config() {
  local output_file="$1" tmpfile="$2"
  local split_dir="${SELECTED_FRPC_SPLIT_DIR:-$FRPC_CONF_DIR}"
  local config="${SELECTED_FRPC_CONFIG:-$FRPC_CONFIG}"
  local service="${SELECTED_FRPC_SERVICE:-frpc}"
  mkdir -p "$split_dir"
  if [[ -f "$output_file" ]]; then
    if confirm "配置 ${output_file} 已存在，是否覆盖" "n"; then
      cp -a "$output_file" "${output_file}.bak.$(date +%Y%m%d-%H%M%S)"
    else
      return 1
    fi
  fi
  install -m 0640 "$tmpfile" "$output_file"
  chown root:"$FRP_USER" "$output_file" 2>/dev/null || true
  ok "已写入：$output_file"
  verify_config_before_restart "${INSTALL_DIR}/frpc" "$config" || return 0
  restart_service_if_present "$service"
}

render_custom_preset_to_file() {
  local preset="$1" out_name safe_name output_file tmpfile content vars=() var def value pattern
  [[ -f "$preset" ]] || fatal "预设不存在：$preset"
  echo
  info "套用自定义预设：$(preset_meta_get "$preset" "name")"
  mapfile -t vars < <(extract_template_vars "$preset")
  content="$(cat "$preset")"

  if (( ${#vars[@]} > 0 )); then
    echo "需要填写变量：${vars[*]}"
    for var in "${vars[@]}"; do
      def="$(preset_meta_get "$preset" "default.${var}")"
      value="$(ask "${var}" "$def")"
      value="$(toml_escape "$value")"
      pattern="\${${var}}"
      content="${content//$pattern/$value}"
      pattern="{{${var}}}"
      content="${content//$pattern/$value}"
    done
  else
    warn "该预设没有声明变量，也没有检测到占位符，将原样写入。"
  fi

  # Remove preset metadata comments from rendered config, keep normal comments.
  content="$(printf '%s\n' "$content" | sed -E '/^#[[:space:]]*(frp-manager-preset-v1|name[[:space:]]*=|desc[[:space:]]*=|vars[[:space:]]*=|default\.[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=)/d')"

  out_name="$(ask "生成到 frpc.d 的文件名，留空用预设文件名" "$(basename "$preset")")"
  out_name="${out_name%.tpl}"; out_name="${out_name%.toml}"; out_name="${out_name%.preset}"
  [[ -n "$(trim "$out_name")" ]] || out_name="custom"
  safe_name="$(safe_filename "$out_name")"
  output_file="${SELECTED_FRPC_SPLIT_DIR:-$FRPC_CONF_DIR}/${safe_name}.toml"
  tmpfile="$(mktemp)"
  printf '%s\n' "$content" > "$tmpfile"

  echo
  echo "========== 渲染后的配置预览 =========="
  cat "$tmpfile"
  echo "======================================"
  if confirm "确认写入该配置" "Y"; then
    write_rendered_frpc_config "$output_file" "$tmpfile"
  else
    warn "已取消写入。"
  fi
  rm -f "$tmpfile"
}

paste_until_eof_to_file() {
  local file="$1" line
  : > "$file"
  echo "请粘贴内容，单独输入 EOF 结束："
  while IFS= read -r line; do
    [[ "$line" == "EOF" ]] && break
    printf '%s\n' "$line" >> "$file"
  done
}

create_custom_preset() {
  create_dirs_and_user
  local preset_id file title desc vars var def tmp body_method
  echo
  info "创建自定义 frpc 预设"
  cat <<'EOF_PRESET_HELP'
预设不是固定模板，而是你自己维护的 TOML 模板。
可用占位符：${name} 或 {{name}}
元数据写在 # 注释里，脚本会读取 vars/default.* 后交互询问。
EOF_PRESET_HELP
  preset_id="$(ask_required "预设文件名，例如 ssh-tcp 或 nas-http" "")"
  preset_id="$(safe_filename "$preset_id")"
  file="${PRESET_DIR}/${preset_id}.tpl"
  if [[ -f "$file" ]]; then
    if ! confirm "预设 ${file} 已存在，是否覆盖" "n"; then
      return 0
    fi
  fi
  title="$(ask "预设显示名" "$preset_id")"
  desc="$(ask "预设描述" "")"
  vars="$(ask "变量列表，英文逗号分隔，例如 name,localIP,localPort,remotePort" "name,localIP,localPort,remotePort")"

  tmp="$(mktemp)"
  {
    echo "# frp-manager-preset-v1"
    echo "# name = \"$(toml_escape "$title")\""
    [[ -n "$desc" ]] && echo "# desc = \"$(toml_escape "$desc")\""
    echo "# vars = \"$(toml_escape "$vars")\""
    local oldifs="$IFS"; IFS=',' read -r -a arr <<< "$vars"; IFS="$oldifs"
    for var in "${arr[@]}"; do
      var="$(trim "$var")"
      [[ -z "$var" ]] && continue
      def="$(ask "变量 ${var} 的默认值，留空无默认" "")"
      echo "# default.${var} = \"$(toml_escape "$def")\""
    done
    echo
  } > "$tmp"

  echo "内容输入方式：1) 粘贴完整 TOML 模板  2) 生成最小代理骨架后再编辑"
  body_method="$(ask "请选择" "1")"
  if [[ "$body_method" == "2" ]]; then
    cat >> "$tmp" <<'EOF_MINIMAL_PROXY'
[[proxies]]
name = "${name}"
type = "tcp"
localIP = "${localIP}"
localPort = ${localPort}
remotePort = ${remotePort}
EOF_MINIMAL_PROXY
  else
    paste_until_eof_to_file "${tmp}.body"
    cat "${tmp}.body" >> "$tmp"
    rm -f "${tmp}.body"
  fi

  install -m 0640 "$tmp" "$file"
  rm -f "$tmp"
  chown root:"$FRP_USER" "$file" 2>/dev/null || true
  ok "已创建预设：$file"
  echo "以后可在菜单中选择该预设，并按变量交互生成 frpc.d/*.toml。"
}

edit_custom_preset() {
  create_dirs_and_user
  local file editor
  SELECTED_PRESET_FILE=""
  choose_preset_file || return 0
  file="$SELECTED_PRESET_FILE"
  editor="${EDITOR:-}"
  if [[ -z "$editor" ]]; then
    if has_cmd nano; then editor="nano"; elif has_cmd vim; then editor="vim"; elif has_cmd vi; then editor="vi"; fi
  fi
  if [[ -n "$editor" ]]; then
    "$editor" "$file"
  else
    warn "未找到 nano/vim/vi。改用覆盖粘贴模式。"
    paste_until_eof_to_file "${file}.new"
    if confirm "是否用新内容覆盖 ${file}" "Y"; then
      cp -a "$file" "${file}.bak.$(date +%Y%m%d-%H%M%S)"
      cat "${file}.new" > "$file"
    fi
    rm -f "${file}.new"
  fi
  chmod 640 "$file" 2>/dev/null || true
  chown root:"$FRP_USER" "$file" 2>/dev/null || true
  ok "预设已保存：$file"
}

show_custom_preset() {
  local file
  SELECTED_PRESET_FILE=""
  choose_preset_file || return 0
  file="$SELECTED_PRESET_FILE"
  echo
  echo "========== $file =========="
  cat "$file"
  echo "======================================"
}

delete_custom_preset() {
  local file
  SELECTED_PRESET_FILE=""
  choose_preset_file || return 0
  file="$SELECTED_PRESET_FILE"
  if confirm "确认删除预设 ${file}" "n"; then
    rm -f "$file"
    ok "已删除：$file"
  fi
}

import_example_presets() {
  create_dirs_and_user
  local file
  warn "这里导入的是可编辑示例，不会强制你使用固定模板；导入后可以在预设管理中编辑。"

  file="${PRESET_DIR}/tcp-custom.tpl"
  if [[ ! -f "$file" ]] || confirm "覆盖示例 ${file}" "n"; then
    cat > "$file" <<'EOF_TCP_PRESET'
# frp-manager-preset-v1
# name = "TCP 自定义暴露"
# desc = "自定义本地 IP/端口和远程端口"
# vars = "name,localIP,localPort,remotePort"
# default.name = "ssh"
# default.localIP = "127.0.0.1"
# default.localPort = "22"
# default.remotePort = "6000"

[[proxies]]
name = "${name}"
type = "tcp"
localIP = "${localIP}"
localPort = ${localPort}
remotePort = ${remotePort}
EOF_TCP_PRESET
  fi

  file="${PRESET_DIR}/http-custom.tpl"
  if [[ ! -f "$file" ]] || confirm "覆盖示例 ${file}" "n"; then
    cat > "$file" <<'EOF_HTTP_PRESET'
# frp-manager-preset-v1
# name = "HTTP 自定义域名"
# desc = "自定义域名访问本地 Web 服务"
# vars = "name,localIP,localPort,domain"
# default.name = "web"
# default.localIP = "127.0.0.1"
# default.localPort = "80"
# default.domain = "www.example.com"

[[proxies]]
name = "${name}"
type = "http"
localIP = "${localIP}"
localPort = ${localPort}
customDomains = ["${domain}"]
EOF_HTTP_PRESET
  fi

  file="${PRESET_DIR}/stcp-custom.tpl"
  if [[ ! -f "$file" ]] || confirm "覆盖示例 ${file}" "n"; then
    cat > "$file" <<'EOF_STCP_PRESET'
# frp-manager-preset-v1
# name = "STCP 安全暴露"
# desc = "需要 visitor 和相同 secretKey 才能访问"
# vars = "name,localIP,localPort,secretKey"
# default.name = "secret-ssh"
# default.localIP = "127.0.0.1"
# default.localPort = "22"
# default.secretKey = "change-me"

[[proxies]]
name = "${name}"
type = "stcp"
secretKey = "${secretKey}"
localIP = "${localIP}"
localPort = ${localPort}
EOF_STCP_PRESET
  fi

  chown root:"$FRP_USER" "$PRESET_DIR"/*.tpl 2>/dev/null || true
  chmod 640 "$PRESET_DIR"/*.tpl 2>/dev/null || true
  ok "示例预设已导入到：$PRESET_DIR。你可以继续编辑它们。"
}

apply_custom_preset() {
  create_dirs_and_user
  local config="${SELECTED_FRPC_CONFIG:-$FRPC_CONFIG}"
  [[ -f "$config" ]] || warn "未检测到 $config，建议先安装/配置 frpc。"
  local file
  SELECTED_PRESET_FILE=""
  choose_preset_file || return 0
  file="$SELECTED_PRESET_FILE"
  render_custom_preset_to_file "$file"
}

paste_raw_frpc_toml() {
  create_dirs_and_user
  local name safe_name output_file tmpfile
  name="$(ask_required "生成到 frpc.d 的文件名" "custom")"
  safe_name="$(safe_filename "$name")"
  output_file="${SELECTED_FRPC_SPLIT_DIR:-$FRPC_CONF_DIR}/${safe_name}.toml"
  tmpfile="$(mktemp)"
  paste_until_eof_to_file "$tmpfile"
  echo
  echo "========== 即将写入的 TOML =========="
  cat "$tmpfile"
  echo "======================================"
  if confirm "确认写入" "Y"; then
    write_rendered_frpc_config "$output_file" "$tmpfile"
  else
    warn "已取消写入。"
  fi
  rm -f "$tmpfile"
}

manage_custom_presets_menu() {
  while true; do
    echo
    info "自定义 frpc 预设管理"
    echo "预设目录：$PRESET_DIR"
    ui_menu_item 1 "创建自定义预设"
    ui_menu_item 2 "编辑自定义预设"
    ui_menu_item 3 "查看自定义预设"
    ui_menu_item 4 "删除自定义预设"
    ui_menu_item 5 "导入可编辑示例预设"
    ui_menu_back
    local choice
    choice="$(ask "请选择" "1")"
    case "$choice" in
      1) create_custom_preset; pause ;;
      2) edit_custom_preset; pause ;;
      3) show_custom_preset; pause ;;
      4) delete_custom_preset; pause ;;
      5) import_example_presets; pause ;;
      0|q|Q) return 0 ;;
      *) warn "无效选择"; pause ;;
    esac
  done
}

add_proxy_manual_wizard() {
  create_dirs_and_user
  local config="${SELECTED_FRPC_CONFIG:-$FRPC_CONFIG}"
  local split_dir="${SELECTED_FRPC_SPLIT_DIR:-$FRPC_CONF_DIR}"
  local service="${SELECTED_FRPC_SERVICE:-frpc}"
  [[ -f "$config" ]] || warn "未检测到 $config，建议先安装/配置 frpc。"
  local type name safe_name file
  echo
  info "高级手动添加 frpc 代理/访问者配置"
  echo "支持类型：tcp udp http https stcp sudp stcp-visitor sudp-visitor"
  type="$(ask "类型" "tcp")"
  case "$type" in tcp|udp|http|https|stcp|sudp|stcp-visitor|sudp-visitor) ;; *) fatal "不支持的类型：$type" ;; esac
  name="$(ask_required "名称 name，必须唯一" "")"
  safe_name="$(safe_filename "$name")"
  file="${split_dir}/${safe_name}.toml"

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
    stcp|sudp) add_proxy_stcp_xtcp_sudp "$type" "$name" "$file" ;;
    stcp-visitor) add_visitor_stcp_xtcp_sudp "stcp" "$name" "$file" ;;
    sudp-visitor) add_visitor_stcp_xtcp_sudp "sudp" "$name" "$file" ;;
  esac

  chown root:"$FRP_USER" "$file" 2>/dev/null || true
  chmod 640 "$file"
  ok "已写入：$file"

  verify_config_before_restart "${INSTALL_DIR}/frpc" "$config" || return 0
  restart_service_if_present "$service"
}

add_proxy_wizard() {
  create_dirs_and_user
  while true; do
    menu_title "客户端 / 代理配置"
    ui_menu_item 1 "套用自定义预设"
    ui_menu_item 2 "管理自定义预设"
    ui_menu_item 3 "高级手动添加" "代理 / 访问者"
    ui_menu_item 4 "直接粘贴 TOML"
    ui_menu_back
    local choice
    choice="$(ask "请选择" "1")"
    case "$choice" in
      1) with_frpc_write_target apply_custom_preset; pause ;;
      2) manage_custom_presets_menu ;;
      3) with_frpc_write_target add_proxy_manual_wizard; pause ;;
      4) with_frpc_write_target paste_raw_frpc_toml; pause ;;
      0|q|Q) return 0 ;;
      *) warn "无效选择"; pause ;;
    esac
  done
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
  echo "frpc 自定义预设：${PRESET_DIR}"
  echo "日志目录：${LOG_DIR}"
  echo "脚本日志：${INSTALLER_LOG}"
  load_installer_config
  echo "GitHub 下载代理：${GH_PROXY:-直连}"
  echo "脚本配置：${INSTALLER_CONFIG}"
  echo
  if has_cmd systemctl; then
    print_service_summary frps
    print_service_summary frpc
  fi
}

export_frps_pairing_code() {
  create_dirs_and_user
  local bind_port kcp_port quic_port default_port token server_addr server_port proto tls_enable pool_count dns_server user_name passphrase payload code
  bind_port="$(read_toml_value "$FRPS_CONFIG" "bindPort")"
  [[ -n "$bind_port" ]] || bind_port="7000"
  kcp_port="$(read_toml_value "$FRPS_CONFIG" "kcpBindPort")"
  quic_port="$(read_toml_value "$FRPS_CONFIG" "quicBindPort")"
  if [[ -s "$TOKEN_FILE" ]]; then
    token="$(tr -d '[:space:]' < "$TOKEN_FILE")"
  else
    token="$(read_toml_value "$FRPS_CONFIG" "auth.token")"
  fi
  [[ -n "$token" ]] || token="$(ask_required "未找到 frps token，请输入 token" "")"

  echo
  info "导出 frps -> frpc 加密接入码"
  server_addr="$(ask_required "新客户端连接的 frps 公网地址/IP/域名" "")"
  echo "通信协议可选：tcp / kcp / quic / websocket / wss"
  proto="$(ask "transport.protocol" "tcp")"
  case "$proto" in tcp|kcp|quic|websocket|wss) ;; *) warn "未知协议，回退 tcp"; proto="tcp" ;; esac
  case "$proto" in
    kcp)
      default_port="${kcp_port:-$bind_port}"
      [[ -n "$kcp_port" ]] || warn "frps 配置未检测到 kcpBindPort；请确认服务端已启用 KCP，或手动输入正确端口。"
      ;;
    quic)
      default_port="${quic_port:-$bind_port}"
      [[ -n "$quic_port" ]] || warn "frps 配置未检测到 quicBindPort；请确认服务端已启用 QUIC，或手动输入正确端口。"
      ;;
    *)
      default_port="$bind_port"
      ;;
  esac
  server_port="$(ask_port "新客户端连接的 frps 端口；${proto} 对应端口" "$default_port")"
  tls_enable="$(ask_yes_no_value "是否启用 frpc->frps TLS；新版默认启用，建议保留" "Y")"
  pool_count="$(ask "连接池数量 transport.poolCount" "0")"
  [[ "$pool_count" =~ ^[0-9]+$ ]] || pool_count=0
  dns_server="$(ask "新客户端自定义 DNS，留空使用系统 DNS" "")"
  user_name="$(ask "新客户端 user，留空不设置" "")"
  passphrase="$(ask "配对码加密口令，留空随机生成" "")"
  [[ -z "$passphrase" ]] && passphrase="$(random_secret | cut -c1-20)"

  payload="$(render_frpc_pairing_payload "$server_addr" "$server_port" "$token" "$proto" "$tls_enable" "$pool_count" "$dns_server" "$user_name")"
  code="$(encrypt_payload_code "IFRP-FRPC-V1" "$passphrase" "$payload")"

  warn "下面的配对码和口令合在一起等同于 frps token，请勿公开。"
  echo
  echo "========== frps -> frpc 加密接入码 =========="
  echo "$code"
  echo "========== 解密码 =========="
  echo "$passphrase"
  echo "========== 一键导入命令（含解密码） =========="
  render_one_click_import_command "frps" "$code" "$passphrase"
  echo "============================================"
}

import_frps_pairing_code() {
  create_dirs_and_user
  local code passphrase strict_verify target_spec payload target name config split_dir token_file log_file store_file service verify_status
  code="${1:-}"
  passphrase="${2:-}"
  strict_verify="${3:-false}"
  target_spec="${4:-}"
  if [[ -z "$code" ]]; then
    warn "请粘贴 frps 接入配对码，格式为 IFRP-FRPC-V1:..."
    code="$(ask_required "frps 接入配对码" "")"
  fi
  [[ -n "$passphrase" ]] || passphrase="$(ask_required "解密码" "")"
  if ! payload="$(decrypt_payload_code "IFRP-FRPC-V1" "$passphrase" "$code" 2>/dev/null)"; then
    warn "解密失败：frps 接入码或解密码不正确。"
    [[ "$strict_verify" == "true" ]] && return 1
    return 0
  fi

  if [[ -n "$target_spec" ]]; then
    target="$target_spec"
  else
    if [[ "$strict_verify" == "true" && ! -t 0 ]]; then
      warn "非交互导入必须指定目标：default 或 instance:<name>。"
      return 1
    fi
    echo "导入目标：1) 默认 frpc  2) 命名 frpc 实例"
    target="$(ask "请选择" "1")"
  fi
  case "$target" in
    1|default|frpc)
      config="$FRPC_CONFIG"
      split_dir="$FRPC_CONF_DIR"
      token_file="$TOKEN_FILE"
      log_file="${LOG_DIR}/frpc.log"
      store_file="$FRPC_STORE"
      service="frpc"
      ;;
    2|instance)
      if [[ "$strict_verify" == "true" ]]; then
        warn "非交互导入命名实例必须使用 instance:<name>。"
        return 1
      fi
      name="$(ask_required "实例名" "")"
      validate_instance_name "$name" || { warn "实例名不合法：$name"; return 0; }
      config="$(instance_frpc_config "$name")"
      split_dir="$(instance_frpc_conf_dir "$name")"
      token_file="$(instance_token_file "$name")"
      log_file="$(instance_log_file "$name")"
      store_file="$(instance_dir "$name")/frpc-store.json"
      service="$(instance_service_name "$name")"
      write_frpc_template_service
      ;;
    instance:*)
      name="${target#instance:}"
      validate_instance_name "$name" || { warn "实例名不合法：$name"; [[ "$strict_verify" == "true" ]] && return 1; return 0; }
      config="$(instance_frpc_config "$name")"
      split_dir="$(instance_frpc_conf_dir "$name")"
      token_file="$(instance_token_file "$name")"
      log_file="$(instance_log_file "$name")"
      store_file="$(instance_dir "$name")/frpc-store.json"
      service="$(instance_service_name "$name")"
      write_frpc_template_service
      ;;
    *) warn "无效选择"; [[ "$strict_verify" == "true" ]] && return 1; return 0 ;;
  esac

  if [[ -f "$config" ]]; then
    if confirm "配置 ${config} 已存在，是否覆盖" "n"; then
      backup_file "$config" >/dev/null || true
    else
      warn "已取消覆盖：$config"
      [[ "$strict_verify" == "true" ]] && return 1
      return 0
    fi
  fi

  write_frpc_config_from_pairing_payload "$config" "$split_dir" "$token_file" "$log_file" "$store_file" "$payload"
  verify_status=0
  verify_config_before_restart "${INSTALL_DIR}/frpc" "$config" || verify_status=$?
  if (( verify_status != 0 )); then
    [[ "$strict_verify" == "true" ]] && return "$verify_status"
    return 0
  fi
  restart_service_if_present "$service"
  ok "已导入 frps 接入配置：$config"
}

manage_named_frpc_service_action() {
  local name service
  name="$(ask_required "实例名" "")"
  validate_instance_name "$name" || { warn "实例名不合法：$name"; return 0; }
  service="$(instance_service_name "$name")"
  manage_single_service_menu "$service"
}

delete_named_frpc_instance() {
  local name dir service
  name="$(ask_required "要删除的实例名" "")"
  validate_instance_name "$name" || { warn "实例名不合法：$name"; return 0; }
  dir="$(instance_dir "$name")"
  service="$(instance_service_name "$name")"
  [[ -d "$dir" ]] || { warn "实例目录不存在：$dir"; return 0; }
  warn "即将删除实例 ${name}，目录：$dir"
  if confirm "确认继续" "n"; then
    service_action "$service" stop "false"
    service_action "$service" disable "false"
    rm -rf "$dir"
    ok "已删除实例：$name"
  fi
}

manage_frpc_instances_menu() {
  while true; do
    menu_title "客户端 / 实例"
    echo "实例目录：$FRPC_CLIENTS_DIR"
    ui_menu_item 1 "列出实例"
    ui_menu_item 2 "新建/重配实例"
    ui_menu_item 3 "从默认 frpc 复制为实例"
    ui_menu_item 4 "服务管理"
    ui_menu_item 5 "删除实例" "危险操作"
    ui_menu_back
    local choice
    choice="$(ask "请选择" "1")"
    case "$choice" in
      1|list) render_frpc_instance_list; pause ;;
      2|create|configure) configure_named_frpc_instance; pause ;;
      3|copy|promote) copy_default_frpc_to_instance; pause ;;
      4|service) manage_named_frpc_service_action; pause ;;
      5|delete|remove) delete_named_frpc_instance; pause ;;
      0|q|Q) return 0 ;;
      *) warn "无效选择"; pause ;;
    esac
  done
}

frps_config_menu() {
  while true; do
    menu_title "服务端 / 配置"
    render_component_status "frps" "${INSTALL_DIR}/frps" "$FRPS_CONFIG" "frps"
    echo "配置：$FRPS_CONFIG"
    ui_menu_item 1 "查看配置"
    ui_menu_item 2 "编辑配置"
    ui_menu_item 3 "校验配置"
    ui_menu_back
    local choice
    choice="$(ask "请选择" "1")"
    case "$choice" in
      1|view) show_config_file "$FRPS_CONFIG" "frps 主配置" "true"; pause ;;
      2|edit) edit_config_file "$FRPS_CONFIG" "frps 主配置" "${INSTALL_DIR}/frps" "frps"; pause ;;
      3|verify) verify_config_interactive "${INSTALL_DIR}/frps" "$FRPS_CONFIG"; pause ;;
      0|q|Q) return 0 ;;
      *) warn "无效选择"; pause ;;
    esac
  done
}

frpc_config_menu() {
  while true; do
    menu_title "客户端 / 配置"
    render_component_status "frpc" "${INSTALL_DIR}/frpc" "$FRPC_CONFIG" "frpc"
    ui_menu_item 1 "默认 frpc"
    ui_menu_item 2 "命名实例"
    ui_menu_back
    local choice name instances=()
    choice="$(ask "请选择" "1")"
    case "$choice" in
      1|default|frpc)
        SELECTED_FRPC_LABEL="默认 frpc"
        SELECTED_FRPC_CONFIG="$FRPC_CONFIG"
        SELECTED_FRPC_SPLIT_DIR="$FRPC_CONF_DIR"
        SELECTED_FRPC_SERVICE="frpc"
        frpc_config_target_menu_direct
        ;;
      2|instance)
        mapfile -t instances < <(list_frpc_instances)
        if (( ${#instances[@]} == 0 )); then
          render_no_frpc_instances_hint
          pause
          continue
        fi
        render_frpc_instance_list
        name="$(ask_required "实例名" "")"
        validate_instance_name "$name" || { warn "实例名不合法：$name"; pause; continue; }
        if [[ ! -f "$(instance_frpc_config "$name")" ]]; then
          warn "命名 frpc 实例不存在或未完成配置：$(instance_frpc_config "$name")"
          warn "上面是当前已有实例；要创建新实例，请到 客户端 -> 实例 -> 新建/重配实例，或 客户端 -> 接入码 导入为 instance:${name}。"
          pause
          continue
        fi
        SELECTED_FRPC_LABEL="实例 ${name}"
        SELECTED_FRPC_CONFIG="$(instance_frpc_config "$name")"
        SELECTED_FRPC_SPLIT_DIR="$(instance_frpc_conf_dir "$name")"
        SELECTED_FRPC_SERVICE="$(instance_service_name "$name")"
        frpc_config_target_menu_direct
        ;;
      0|q|Q) return 0 ;;
      *) warn "无效选择"; pause ;;
    esac
  done
}

select_existing_frpc_target() {
  local target name config instances=()
  echo "选择客户端：1) 默认 frpc  2) 命名 frpc 实例"
  target="$(ask "请选择" "1")"
  case "$target" in
    1|default|frpc)
      [[ -f "$FRPC_CONFIG" ]] || { warn "默认 frpc 主配置不存在：$FRPC_CONFIG"; return 1; }
      SELECTED_FRPC_LABEL="默认 frpc"
      SELECTED_FRPC_CONFIG="$FRPC_CONFIG"
      SELECTED_FRPC_SPLIT_DIR="$FRPC_CONF_DIR"
      SELECTED_FRPC_SERVICE="frpc"
      SELECTED_FRPC_LOG_FILE="${LOG_DIR}/frpc.log"
      ;;
    2|instance)
      mapfile -t instances < <(list_frpc_instances)
      if (( ${#instances[@]} == 0 )); then
        render_no_frpc_instances_hint
        return 1
      fi
      render_frpc_instance_list
      name="$(ask_required "实例名" "")"
      validate_instance_name "$name" || { warn "实例名不合法：$name"; return 1; }
      config="$(instance_frpc_config "$name")"
      if [[ ! -f "$config" ]]; then
        warn "命名 frpc 实例不存在或未完成配置：$config"
        return 1
      fi
      SELECTED_FRPC_LABEL="实例 ${name}"
      SELECTED_FRPC_CONFIG="$config"
      SELECTED_FRPC_SPLIT_DIR="$(instance_frpc_conf_dir "$name")"
      SELECTED_FRPC_SERVICE="$(instance_service_name "$name")"
      SELECTED_FRPC_LOG_FILE="$(instance_log_file "$name")"
      ;;
    *) warn "无效选择"; return 1 ;;
  esac
}

select_existing_named_frpc_target() {
  local name config instances=()
  mapfile -t instances < <(list_frpc_instances)
  if (( ${#instances[@]} == 0 )); then
    render_no_frpc_instances_hint
    return 1
  fi
  render_frpc_instance_list
  name="$(ask_required "实例名" "")"
  validate_instance_name "$name" || { warn "实例名不合法：$name"; return 1; }
  config="$(instance_frpc_config "$name")"
  if [[ ! -f "$config" ]]; then
    warn "命名 frpc 实例不存在或未完成配置：$config"
    return 1
  fi
  SELECTED_FRPC_LABEL="实例 ${name}"
  SELECTED_FRPC_CONFIG="$config"
  SELECTED_FRPC_SPLIT_DIR="$(instance_frpc_conf_dir "$name")"
  SELECTED_FRPC_SERVICE="$(instance_service_name "$name")"
  SELECTED_FRPC_LOG_FILE="$(instance_log_file "$name")"
}

show_frpc_log_menu() {
  select_existing_frpc_target || return 0
  show_service_log "$SELECTED_FRPC_SERVICE" "200" "false"
}

frpc_config_target_menu_direct() {
  while true; do
    menu_title "客户端 / 配置 / ${SELECTED_FRPC_LABEL}"
    echo "主配置：$SELECTED_FRPC_CONFIG"
    echo "拆分目录：$SELECTED_FRPC_SPLIT_DIR"
    ui_menu_item 1 "查看配置"
    ui_menu_item 2 "编辑主配置"
    ui_menu_item 3 "编辑拆分配置"
    ui_menu_item 4 "校验配置"
    ui_menu_back
    local choice
    choice="$(ask "请选择" "1")"
    case "$choice" in
      1|view) show_config_file "$SELECTED_FRPC_CONFIG" "${SELECTED_FRPC_LABEL} 主配置" "true"; show_frpc_split_configs_for_dir "$SELECTED_FRPC_SPLIT_DIR" "true"; pause ;;
      2|edit-main) edit_config_file "$SELECTED_FRPC_CONFIG" "${SELECTED_FRPC_LABEL} 主配置" "${INSTALL_DIR}/frpc" "$SELECTED_FRPC_SERVICE"; pause ;;
      3|edit-split)
        choose_frpc_split_config "$SELECTED_FRPC_SPLIT_DIR" || { pause; continue; }
        edit_config_file "$SELECTED_CONFIG_FILE" "${SELECTED_FRPC_LABEL} 拆分配置" "${INSTALL_DIR}/frpc" "$SELECTED_FRPC_SERVICE"
        pause
        ;;
      4|verify) verify_config_interactive "${INSTALL_DIR}/frpc" "$SELECTED_FRPC_CONFIG"; pause ;;
      0|q|Q) return 0 ;;
      *) warn "无效选择"; pause ;;
    esac
  done
}

render_frps_menu() {
  ui_menu_item 1 "安装/更新"
  ui_menu_item 2 "服务管理" "启动 / 停止 / 重启 / 自启"
  ui_menu_item 3 "接入码" "导出给新 frpc"
  ui_menu_item 4 "配置" "查看 / 编辑 / 校验"
  ui_menu_item 5 "日志"
  ui_menu_back
}

frps_management_menu() {
  while true; do
    menu_title "服务端"
    render_component_status "frps" "${INSTALL_DIR}/frps" "$FRPS_CONFIG" "frps"
    echo
    render_frps_menu
    local choice
    choice="$(ask "请选择" "1")"
    case "$choice" in
      1) install_frps_flow; pause ;;
      2) manage_single_service_menu frps; pause ;;
      3) export_frps_pairing_code; pause ;;
      4) frps_config_menu ;;
      5) show_service_log frps "200" "false"; pause ;;
      0|q|Q) return 0 ;;
      *) warn "无效选择"; pause ;;
    esac
  done
}

render_frpc_menu() {
  ui_menu_item 1 "安装/更新"
  ui_menu_item 2 "服务管理" "启动 / 停止 / 重启 / 自启"
  ui_menu_item 3 "实例" "多 frpc 客户端"
  ui_menu_item 4 "接入码" "导入 frps 配对码"
  ui_menu_item 5 "代理配置" "TCP / HTTP / STCP 等"
  ui_menu_item 6 "XTCP" "打洞配置 / 导入码"
  ui_menu_item 7 "配置" "查看 / 编辑 / 校验"
  ui_menu_item 8 "日志"
  ui_menu_back
}

frpc_management_menu() {
  while true; do
    menu_title "客户端"
    render_component_status "frpc" "${INSTALL_DIR}/frpc" "$FRPC_CONFIG" "frpc"
    echo
    render_frpc_menu
    local choice
    choice="$(ask "请选择" "1")"
    case "$choice" in
      1) install_frpc_flow; pause ;;
      2) manage_single_service_menu frpc; pause ;;
      3) manage_frpc_instances_menu ;;
      4) import_frps_pairing_code; pause ;;
      5) add_proxy_wizard; pause ;;
      6) xtcp_pair_menu ;;
      7) frpc_config_menu ;;
      8) show_frpc_log_menu; pause ;;
      0|q|Q) return 0 ;;
      *) warn "无效选择"; pause ;;
    esac
  done
}

tools_menu() {
  while true; do
    menu_title "工具/维护"
    ui_menu_item 1 "仅安装/更新二进制"
    ui_menu_item 2 "全局校验" "frps + frpc"
    ui_menu_item 3 "安装摘要"
    ui_menu_item 4 "GitHub 下载代理"
    ui_menu_item 5 "修复文件日志"
    ui_menu_item 6 "卸载 frp" "危险操作"
    ui_menu_back
    local choice
    choice="$(ask "请选择" "1")"
    case "$choice" in
      1) install_or_update_binaries; pause ;;
      2) verify_all_configs; pause ;;
      3) show_summary; pause ;;
      4) configure_github_proxy; pause ;;
      5) fix_log_config_menu; pause ;;
      6) uninstall_frp; pause ;;
      0|q|Q) return 0 ;;
      *) warn "无效选择"; pause ;;
    esac
  done
}

manage_single_service_menu() {
  local svc="$1" action
  if ! has_cmd systemctl; then
    warn "当前系统没有 systemctl，无法管理 ${svc}。"
    return 0
  fi
  menu_title "${svc} 启动/停止/重启"
  print_service_summary "$svc"
  if ! service_exists "$svc"; then
    warn "请先安装/写入 ${svc}.service。"
    return 0
  fi
  ui_menu_item 1 "状态"
  ui_menu_item 2 "启动"
  ui_menu_item 3 "停止"
  ui_menu_item 4 "重启"
  ui_menu_item 5 "日志" "systemd"
  ui_menu_item 6 "开机自启"
  ui_menu_item 7 "取消自启"
  ui_menu_back
  action="$(ask "请选择" "1")"
  case "$action" in
    1|status) service_action "$svc" status ;;
    2|start) service_action "$svc" start ;;
    3|stop) service_action "$svc" stop ;;
    4|restart) service_action "$svc" restart ;;
    5|logs) service_action "$svc" logs ;;
    6|enable) service_action "$svc" enable ;;
    7|disable) service_action "$svc" disable ;;
    0|q|Q) return 0 ;;
    *) warn "无效选择" ;;
  esac
}

verify_all_configs() {
  local checked=0 failed=0 instances=() instance config

  if [[ -x "${INSTALL_DIR}/frps" && -f "$FRPS_CONFIG" ]]; then
    checked=1
    verify_config "${INSTALL_DIR}/frps" "$FRPS_CONFIG" || failed=1
  else
    warn "跳过 frps：未同时检测到 ${INSTALL_DIR}/frps 和 $FRPS_CONFIG。"
  fi

  if [[ -x "${INSTALL_DIR}/frpc" && -f "$FRPC_CONFIG" ]]; then
    checked=1
    verify_config "${INSTALL_DIR}/frpc" "$FRPC_CONFIG" || failed=1
  else
    warn "跳过 frpc：未同时检测到 ${INSTALL_DIR}/frpc 和 $FRPC_CONFIG。"
  fi

  mapfile -t instances < <(list_frpc_instances)
  for instance in "${instances[@]}"; do
    config="$(instance_frpc_config "$instance")"
    if [[ -x "${INSTALL_DIR}/frpc" && -f "$config" ]]; then
      checked=1
      verify_config "${INSTALL_DIR}/frpc" "$config" || failed=1
    else
      warn "跳过 frpc@${instance}：未同时检测到 ${INSTALL_DIR}/frpc 和 $config。"
    fi
  done

  if (( checked == 0 )); then
    warn "没有可校验的 frp 配置。"
  elif (( failed != 0 )); then
    warn "部分配置校验失败，请先修复配置。"
  else
    ok "配置校验完成。"
  fi
  return 0
}

redact_config_stream() {
  sed -E \
    -e 's#(auth\.token[[:space:]]*=[[:space:]]*").*(")#\1******\2#g' \
    -e 's#(token[[:space:]]*=[[:space:]]*").*(")#\1******\2#g' \
    -e 's#(secretKey[[:space:]]*=[[:space:]]*").*(")#\1******\2#g' \
    -e 's#(webServer\.password[[:space:]]*=[[:space:]]*").*(")#\1******\2#g' \
    -e 's#(httpPassword[[:space:]]*=[[:space:]]*").*(")#\1******\2#g' \
    -e 's#(password[[:space:]]*=[[:space:]]*").*(")#\1******\2#g' \
    -e 's#(GH_PROXY=).+#\1******#g'
}

show_config_file() {
  local file="$1" title="$2" reveal="$3"
  echo
  echo "========== ${title} =========="
  if [[ ! -f "$file" ]]; then
    warn "文件不存在：$file"
    return 0
  fi
  echo "路径：$file"
  echo "----------------------------------------"
  if [[ "$reveal" == "true" ]]; then
    nl -ba "$file"
  else
    redact_config_stream < "$file" | nl -ba
  fi
}

show_token_file() {
  local reveal="$1"
  echo
  echo "========== 鉴权 Token 文件 =========="
  if [[ ! -f "$TOKEN_FILE" ]]; then
    warn "文件不存在：$TOKEN_FILE"
    return 0
  fi
  echo "路径：$TOKEN_FILE"
  echo "----------------------------------------"
  if [[ "$reveal" == "true" ]]; then
    nl -ba "$TOKEN_FILE"
  else
    printf '     1	******
'
  fi
}

show_frpc_split_configs_for_dir() {
  local dir="$1" reveal="$2" files=() f
  echo
  echo "========== frpc 拆分代理配置 =========="
  echo "目录：$dir"
  if [[ ! -d "$dir" ]]; then
    warn "目录不存在：$dir"
    return 0
  fi
  mapfile -d '' -t files < <(find "$dir" -maxdepth 1 -type f -name '*.toml' -print0 2>/dev/null | sort -z)
  if (( ${#files[@]} == 0 )); then
    warn "没有找到拆分代理配置：${dir}/*.toml"
    return 0
  fi
  for f in "${files[@]}"; do
    show_config_file "$f" "$(basename "$f")" "$reveal"
  done
}

show_frpc_split_configs() {
  show_frpc_split_configs_for_dir "$FRPC_CONF_DIR" "$1"
}

choose_editor() {
  local editor="${EDITOR:-}"
  if [[ -n "$editor" ]] && command -v "$editor" >/dev/null 2>&1; then
    printf '%s' "$editor"
    return 0
  fi
  if has_cmd nano; then
    printf 'nano'
  elif has_cmd vim; then
    printf 'vim'
  elif has_cmd vi; then
    printf 'vi'
  else
    return 1
  fi
}

backup_file() {
  local file="$1" backup
  [[ -f "$file" ]] || return 1
  backup="${file}.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "$file" "$backup"
  printf '%s' "$backup"
}

edit_config_file() {
  local file="$1" title="$2" bin="${3:-}" service="${4:-}" editor backup tmp
  echo
  info "编辑 ${title}"
  echo "路径：$file"
  mkdir -p "${file%/*}"
  if [[ ! -f "$file" ]]; then
    if confirm "文件不存在，是否创建" "Y"; then
      : > "$file"
    else
      return 0
    fi
  fi

  backup="$(backup_file "$file" || true)"
  [[ -n "$backup" ]] && ok "已备份：$backup"

  if editor="$(choose_editor)"; then
    "$editor" "$file"
  else
    warn "未找到 nano/vim/vi，改用粘贴覆盖模式。"
    tmp="$(mktemp)"
    paste_until_eof_to_file "$tmp"
    if confirm "是否用粘贴内容覆盖 ${file}" "Y"; then
      cp "$tmp" "$file"
    fi
    rm -f "$tmp"
  fi

  chown root:"$FRP_USER" "$file" 2>/dev/null || true
  chmod 640 "$file" 2>/dev/null || true

  if [[ -n "$bin" ]]; then
    if ! verify_config "$bin" "$file"; then
      warn "配置校验失败：$file"
      if [[ -n "$backup" ]] && confirm "是否恢复备份" "Y"; then
        cp -a "$backup" "$file"
        ok "已恢复：$backup"
      fi
      return 0
    fi
  fi

  if [[ -n "$service" ]] && service_exists "$service"; then
    restart_service_if_present "$service"
  fi
}

choose_frpc_split_config() {
  local dir="${1:-$FRPC_CONF_DIR}" files=() f idx choice
  SELECTED_CONFIG_FILE=""
  [[ -d "$dir" ]] || { warn "目录不存在：$dir"; return 1; }
  mapfile -d '' -t files < <(find "$dir" -maxdepth 1 -type f -name '*.toml' -print0 2>/dev/null | sort -z)
  if (( ${#files[@]} == 0 )); then
    warn "没有找到配置：${dir}/*.toml"
    return 1
  fi
  echo
  info "选择 frpc 拆分配置"
  idx=1
  for f in "${files[@]}"; do
    printf '%s) %s\n' "$idx" "$(basename "$f")"
    idx=$((idx+1))
  done
  echo "0) 返回"
  choice="$(ask "请选择" "1")"
  [[ "$choice" == "0" || "$choice" =~ ^[Qq]$ ]] && return 1
  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#files[@]} )); then
    SELECTED_CONFIG_FILE="${files[$((choice-1))]}"
    return 0
  fi
  warn "无效选择。"
  return 1
}

show_log_file() {
  local file="$1" title="$2" lines="${3:-200}" follow="${4:-false}"
  echo
  echo "========== ${title} =========="
  echo "路径：$file"
  echo "----------------------------------------"
  if [[ ! -f "$file" ]]; then
    warn "日志文件不存在：$file"
    warn "如果刚启用文件日志，请先重启对应服务；如果没有连接/报错，日志也可能暂时为空。"
    return 0
  fi
  if [[ ! -s "$file" ]]; then
    warn "日志文件存在但为空：$file"
    warn "frp 通常在启动、客户端连接、代理访问、错误发生时写日志；没有事件时不会持续刷屏。"
  fi
  if [[ "$follow" == "true" ]]; then
    tail -n "$lines" -F "$file" || true
  else
    tail -n "$lines" "$file" || true
  fi
}

show_journal_log() {
  local service="$1" lines="${2:-200}" follow="${3:-false}" file=""
  case "$service" in
    frps) file="${LOG_DIR}/frps.log" ;;
    frpc) file="${LOG_DIR}/frpc.log" ;;
    frpc@*)
      local instance="${service#frpc@}"
      if validate_instance_name "$instance"; then
        file="$(instance_log_file "$instance")"
      fi
      ;;
  esac
  echo
  echo "========== ${service} systemd 日志 =========="
  echo "----------------------------------------"
  if [[ -n "$file" ]]; then
    warn "当前脚本默认把 ${service} 业务日志写到文件：${file}；systemd 日志通常只显示服务启动/停止。"
  fi
  if ! has_cmd journalctl; then
    warn "当前系统没有 journalctl。"
    return 0
  fi
  if [[ "$follow" == "true" ]]; then
    journalctl -u "$service" -n "$lines" -f --no-pager || true
  else
    journalctl -u "$service" -n "$lines" --no-pager || true
  fi
}

show_service_log() {
  local service="$1" lines="${2:-200}" follow="${3:-false}" file="" conf=""
  case "$service" in
    frps) file="${LOG_DIR}/frps.log"; conf="$FRPS_CONFIG" ;;
    frpc) file="${LOG_DIR}/frpc.log"; conf="$FRPC_CONFIG" ;;
    frpc@*)
      local instance="${service#frpc@}"
      validate_instance_name "$instance" || { warn "实例名不合法：$instance"; return 0; }
      file="$(instance_log_file "$instance")"
      conf="$(instance_frpc_config "$instance")"
      ;;
    *) warn "未知服务：$service"; return 0 ;;
  esac

  echo
  info "查看 ${service} 综合日志"
  if [[ -f "$conf" ]]; then
    local log_to
    log_to="$(grep -E '^[[:space:]]*log\.to[[:space:]]*=' "$conf" | tail -n1 || true)"
    if [[ -n "$log_to" ]]; then
      echo "配置：${log_to}"
    else
      warn "${conf} 里没有 log.to，建议选择日志菜单里的“一键修复/启用文件日志”。"
    fi
  else
    warn "配置文件不存在：$conf"
  fi

  if [[ -f "$file" ]]; then
    show_log_file "$file" "${service} 文件日志" "$lines" "$follow"
  else
    warn "未找到 ${service} 文件日志：$file"
    warn "下面显示 systemd 日志；如果只看到 Started/Stopped，说明 frp 没有向 stdout 输出业务日志。"
    show_journal_log "$service" "$lines" "$follow"
  fi
}

patch_log_config_file() {
  local conf="$1" file="$2" title="$3" changed=0
  [[ -f "$conf" ]] || { warn "配置文件不存在：$conf"; return 0; }
  cp -a "$conf" "${conf}.bak.$(date +%Y%m%d-%H%M%S)"

  if grep -Eq '^[[:space:]]*log\.to[[:space:]]*=' "$conf"; then
    sed -i -E "s#^[[:space:]]*log\.to[[:space:]]*=.*#log.to = \"${file}\"#" "$conf"
  else
    printf '\n# Logs.\nlog.to = "%s"\n' "$file" >> "$conf"
  fi

  if grep -Eq '^[[:space:]]*log\.level[[:space:]]*=' "$conf"; then
    sed -i -E 's#^[[:space:]]*log\.level[[:space:]]*=.*#log.level = "info"#' "$conf"
  else
    printf 'log.level = "info"\n' >> "$conf"
  fi

  if grep -Eq '^[[:space:]]*log\.maxDays[[:space:]]*=' "$conf"; then
    sed -i -E 's#^[[:space:]]*log\.maxDays[[:space:]]*=.*#log.maxDays = 7#' "$conf"
  else
    printf 'log.maxDays = 7\n' >> "$conf"
  fi

  if grep -Eq '^[[:space:]]*log\.disablePrintColor[[:space:]]*=' "$conf"; then
    sed -i -E 's#^[[:space:]]*log\.disablePrintColor[[:space:]]*=.*#log.disablePrintColor = true#' "$conf"
  else
    printf 'log.disablePrintColor = true\n' >> "$conf"
  fi

  chown root:"$FRP_USER" "$conf" 2>/dev/null || true
  chmod 640 "$conf" 2>/dev/null || true
  ok "已修复 ${title} 日志配置：$conf -> $file"
}

fix_log_config_target() {
  local bin="$1" conf="$2" log_file="$3" service="$4" title="$5"
  if [[ ! -f "$conf" ]]; then
    warn "跳过 ${title}：配置文件不存在：$conf"
    return 1
  fi
  patch_log_config_file "$conf" "$log_file" "$title"
  touch "$log_file" 2>/dev/null || warn "无法创建日志文件：$log_file"
  chown "$FRP_USER":"$FRP_USER" "$log_file" 2>/dev/null || true
  verify_config_before_restart "$bin" "$conf"
}

fix_log_config_menu() {
  local choice restart_services=() instances=() instance config log_file service
  echo
  info "一键修复/启用文件日志"
  ui_menu_item 1 "修复 frps 文件日志配置"
  ui_menu_item 2 "修复默认 frpc 文件日志配置"
  ui_menu_item 3 "修复命名 frpc 实例文件日志配置"
  ui_menu_item 4 "修复全部" "frps + 默认 frpc + 命名实例"
  ui_menu_back
  choice="$(ask "请选择" "4")"
  mkdir -p "$LOG_DIR"
  if id "$FRP_USER" >/dev/null 2>&1; then
    chown -R "$FRP_USER":"$FRP_USER" "$LOG_DIR" 2>/dev/null || true
  fi
  chmod 750 "$LOG_DIR" 2>/dev/null || true

  case "$choice" in
    1|frps)
      if fix_log_config_target "${INSTALL_DIR}/frps" "$FRPS_CONFIG" "${LOG_DIR}/frps.log" "frps" "frps"; then
        restart_services+=(frps)
      fi
      ;;
    2|frpc)
      if fix_log_config_target "${INSTALL_DIR}/frpc" "$FRPC_CONFIG" "${LOG_DIR}/frpc.log" "frpc" "frpc"; then
        restart_services+=(frpc)
      fi
      ;;
    3|instance)
      select_existing_named_frpc_target || return 0
      if fix_log_config_target "${INSTALL_DIR}/frpc" "$SELECTED_FRPC_CONFIG" "$SELECTED_FRPC_LOG_FILE" "$SELECTED_FRPC_SERVICE" "$SELECTED_FRPC_SERVICE"; then
        restart_services+=("$SELECTED_FRPC_SERVICE")
      fi
      ;;
    4|all|全部)
      if fix_log_config_target "${INSTALL_DIR}/frps" "$FRPS_CONFIG" "${LOG_DIR}/frps.log" "frps" "frps"; then
        restart_services+=(frps)
      fi
      if fix_log_config_target "${INSTALL_DIR}/frpc" "$FRPC_CONFIG" "${LOG_DIR}/frpc.log" "frpc" "frpc"; then
        restart_services+=(frpc)
      fi
      mapfile -t instances < <(list_frpc_instances)
      for instance in "${instances[@]}"; do
        config="$(instance_frpc_config "$instance")"
        log_file="$(instance_log_file "$instance")"
        service="$(instance_service_name "$instance")"
        if fix_log_config_target "${INSTALL_DIR}/frpc" "$config" "$log_file" "$service" "$service"; then
          restart_services+=("$service")
        fi
      done
      ;;
    0|q|Q) return 0 ;;
    *) warn "无效选择"; return 0 ;;
  esac

  if (( ${#restart_services[@]} == 0 )); then
    warn "没有通过校验的日志配置需要重启。"
    return 0
  fi

  if confirm "是否现在重启相关服务让日志配置生效" "Y"; then
    local svc
    for svc in "${restart_services[@]}"; do
      if service_exists "$svc"; then
        service_action "$svc" restart "true"
      else
        warn "未找到 ${svc}.service；日志配置已写入，安装服务后再启动。"
      fi
    done
  else
    warn "未重启服务，新的 log.to 要等下次重启后生效。"
  fi
}

uninstall_frp() {
  local instances=() instance service
  warn "即将卸载 frp。"
  if ! confirm "确认继续" "n"; then return; fi
  service_action frps stop "false"
  service_action frps disable "false"
  service_action frpc stop "false"
  service_action frpc disable "false"
  mapfile -t instances < <(list_frpc_instances)
  for instance in "${instances[@]}"; do
    service="$(instance_service_name "$instance")"
    service_action "$service" stop "false"
    service_action "$service" disable "false"
  done
  rm -f /etc/systemd/system/frps.service /etc/systemd/system/frpc.service /etc/systemd/system/frpc@.service
  has_cmd systemctl && systemctl daemon-reload 2>/dev/null || true
  rm -f "${INSTALL_DIR}/frps" "${INSTALL_DIR}/frpc"
  if confirm "是否删除配置目录 ${CONFIG_DIR}" "n"; then
    rm -rf "$CONFIG_DIR"
  fi
  if confirm "是否删除日志目录 ${LOG_DIR}" "n"; then
    rm -rf "$LOG_DIR"
  fi
  ok "卸载完成。"
}

render_main_menu() {
  ui_menu_item 1 "服务端 frps" "安装 / 配置 / 接入码 / 日志"
  ui_menu_item 2 "客户端 frpc" "实例 / 代理 / XTCP / 日志"
  ui_menu_item 3 "工具/维护" "全局校验 / 摘要 / 日志修复 / 卸载"
  ui_menu_back "退出"
}

main_menu() {
  need_root
  load_installer_config
  while true; do
    print_banner
    render_main_menu
    local choice
    choice="$(ask "请选择" "1")"
    case "$choice" in
      1) frps_management_menu ;;
      2) frpc_management_menu ;;
      3) tools_menu ;;
      0|q|Q) exit 0 ;;
      *) warn "无效选择"; pause ;;
    esac
  done
}

print_usage() {
  cat <<EOF_USAGE
用法：
  bash frp.sh
  bash frp.sh --import-frps-code <接入码> <解密码> [default|instance:<name>]
  bash frp.sh --import-xtcp-code <导入码> <解密码> [default|instance:<name>]
  bash frp.sh --xtcp-summary <配置文件或目录>
  bash frp.sh --repair-xtcp <配置文件或目录> [quic|kcp] [fallbackTimeoutMs]
  bash frp.sh --service <frps|frpc|frpc@name> <status|start|stop|restart|enable|disable>
EOF_USAGE
}

run_cli() {
  local cmd="${1:-}" service action
  case "$cmd" in
    --import-frps-code)
      need_root
      load_installer_config
      import_frps_pairing_code "${2:-}" "${3:-}" "true" "${4:-}"
      ;;
    --import-xtcp-code)
      need_root
      load_installer_config
      import_xtcp_code_to_visitor "${2:-}" "${3:-}" "true" "${4:-}"
      ;;
    --xtcp-summary)
      [[ -n "${2:-}" ]] || fatal "缺少 XTCP 配置文件或目录路径。"
      render_xtcp_path_summary "${2:-}"
      ;;
    --repair-xtcp)
      need_root
      [[ -n "${2:-}" ]] || fatal "缺少 XTCP 配置文件或目录路径。"
      repair_xtcp_path "${2:-}" "${3:-quic}" "false" "${4:-5000}" "true"
      render_xtcp_path_summary "${2:-}"
      ;;
    --service)
      need_root
      has_cmd systemctl || fatal "当前系统没有 systemctl，无法管理服务。"
      service="${2:-}"
      action="${3:-status}"
      [[ -n "$service" ]] || fatal "缺少服务名。"
      case "$action" in
        status|start|stop|restart|enable|disable)
          service_action "$service" "$action"
          if [[ "$action" != "status" && "${SERVICE_ACTION_STATUS:-0}" != "0" ]]; then
            return "$SERVICE_ACTION_STATUS"
          fi
          ;;
        *) fatal "未知服务操作：$action" ;;
      esac
      ;;
    -h|--help|help)
      print_usage
      ;;
    "")
      main_menu
      ;;
    *)
      print_usage
      fatal "未知参数：$cmd"
      ;;
  esac
}

if [[ "${FRP_LIB_ONLY:-0}" != "1" ]]; then
  run_cli "$@"
fi
