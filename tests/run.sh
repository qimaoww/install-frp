#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

export FRP_LIB_ONLY=1
# shellcheck source=/dev/null
source "${ROOT_DIR}/frp.sh"

INSTALL_DIR="${TMP_DIR}/usr/local/bin"
CONFIG_DIR="${TMP_DIR}/etc/frp"
FRPC_CONF_DIR="${CONFIG_DIR}/frpc.d"
PRESET_DIR="${CONFIG_DIR}/presets.d"
LOG_DIR="${TMP_DIR}/var/log/frp"
TOKEN_FILE="${CONFIG_DIR}/token"
FRPS_CONFIG="${CONFIG_DIR}/frps.toml"
FRPC_CONFIG="${CONFIG_DIR}/frpc.toml"
FRPC_STORE="${CONFIG_DIR}/frpc-store.json"
INSTALLER_CONFIG="${CONFIG_DIR}/installer.env"
INSTALLER_LOG="${LOG_DIR}/installer.log"
FRPC_CLIENTS_DIR="${CONFIG_DIR}/clients"

pass_count=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  pass_count=$((pass_count + 1))
  printf 'ok %d - %s\n' "$pass_count" "$*"
}

assert_eq() {
  local expected="$1" actual="$2" msg="$3"
  [[ "$actual" == "$expected" ]] || fail "${msg}: expected '${expected}', got '${actual}'"
  pass "$msg"
}

assert_contains() {
  local needle="$1" file="$2" msg="$3"
  grep -Fq -- "$needle" "$file" || fail "${msg}: missing '${needle}' in ${file}"
  pass "$msg"
}

assert_not_contains() {
  local needle="$1" file="$2" msg="$3"
  if grep -Fq -- "$needle" "$file"; then
    fail "${msg}: unexpected '${needle}' in ${file}"
  fi
  pass "$msg"
}

require_function() {
  local name="$1"
  declare -F "$name" >/dev/null || fail "missing function ${name}"
  pass "function ${name} exists"
}

test_instance_helpers_exist() {
  require_function validate_instance_name
  require_function instance_dir
  require_function instance_frpc_config
  require_function instance_frpc_conf_dir
  require_function instance_token_file
  require_function instance_log_file
  require_function instance_service_name
}

test_instance_paths() {
  validate_instance_name "home" >/dev/null
  ! validate_instance_name "../bad" >/dev/null 2>&1 || fail "invalid instance name was accepted"
  assert_eq "${FRPC_CLIENTS_DIR}/home" "$(instance_dir home)" "instance dir"
  assert_eq "${FRPC_CLIENTS_DIR}/home/frpc.toml" "$(instance_frpc_config home)" "instance main config"
  assert_eq "${FRPC_CLIENTS_DIR}/home/frpc.d" "$(instance_frpc_conf_dir home)" "instance split config dir"
  assert_eq "${FRPC_CLIENTS_DIR}/home/token" "$(instance_token_file home)" "instance token file"
  assert_eq "${LOG_DIR}/frpc-home.log" "$(instance_log_file home)" "instance log file"
  assert_eq "frpc@home" "$(instance_service_name home)" "instance service name"
}

test_frpc_base_config_renderer() {
  require_function write_token_file
  require_function write_frpc_base_config

  local token_path="${TMP_DIR}/token-source"
  local config_path="${TMP_DIR}/frpc.toml"
  local split_dir="${TMP_DIR}/frpc.d"
  local log_path="${TMP_DIR}/frpc.log"
  mkdir -p "$split_dir"

  write_token_file "$token_path" "secret-token"
  assert_contains "secret-token" "$token_path" "token file content"

  write_frpc_base_config \
    "$config_path" \
    "$split_dir" \
    "$token_path" \
    "$log_path" \
    "frps.example.com" \
    "7000" \
    "homeuser" \
    "tcp" \
    "true" \
    "2" \
    "1.1.1.1" \
    "127.0.0.1" \
    "7400" \
    "admin" \
    "admin-pass" \
    "${TMP_DIR}/frpc-store.json" \
    "true"

  assert_contains 'serverAddr = "frps.example.com"' "$config_path" "server address rendered"
  assert_contains 'includes = ["'"$split_dir"'/*.toml"]' "$config_path" "split include rendered"
  assert_contains 'auth.tokenSource.type = "file"' "$config_path" "token source type rendered"
  assert_contains 'auth.tokenSource.file.path = "'"$token_path"'"' "$config_path" "token source path rendered"
  assert_contains 'transport.tls.enable = true' "$config_path" "tls rendered"
  assert_contains '[store]' "$config_path" "store section rendered"
}

test_named_instance_lifecycle_helpers() {
  require_function list_frpc_instances
  require_function render_frpc_template_service
  require_function write_frpc_template_service
  require_function configure_named_frpc_instance
  require_function frps_management_menu
  require_function manage_frpc_instances_menu
  require_function frpc_management_menu

  mkdir -p "${FRPC_CLIENTS_DIR}/home" "${FRPC_CLIENTS_DIR}/company" "${FRPC_CLIENTS_DIR}/empty"
  : > "${FRPC_CLIENTS_DIR}/home/frpc.toml"
  : > "${FRPC_CLIENTS_DIR}/company/frpc.toml"

  assert_eq $'company\nhome' "$(list_frpc_instances)" "named instances listed from configs"

  local service_path="${TMP_DIR}/frpc@.service"
  render_frpc_template_service > "$service_path"
  assert_contains 'Description=frp client instance %i service' "$service_path" "template description"
  assert_contains 'ExecStart='"${INSTALL_DIR}"'/frpc -c '"${FRPC_CLIENTS_DIR}"'/%i/frpc.toml' "$service_path" "template execstart"
}

test_config_edit_helpers() {
  require_function choose_editor
  require_function backup_file
  require_function edit_config_file
  require_function choose_frpc_split_config
  require_function config_management_menu

  local sample="${TMP_DIR}/sample.toml"
  printf 'value = "original"\n' > "$sample"
  local backup
  backup="$(backup_file "$sample")"
  [[ -f "$backup" ]] || fail "backup file was not created"
  assert_contains 'value = "original"' "$backup" "backup content"

  EDITOR="/bin/true"
  assert_eq "/bin/true" "$(choose_editor)" "editor selected from EDITOR"
}

test_xtcp_import_code_helpers() {
  require_function render_xtcp_payload
  require_function encrypt_payload_code
  require_function decrypt_payload_code
  require_function parse_xtcp_payload_value
  require_function write_xtcp_exposed_config
  require_function write_xtcp_visitor_config_from_payload
  require_function tune_xtcp_config_file
  require_function render_xtcp_config_summary
  require_function xtcp_pair_menu

  local payload code decoded visitor_file exposed_file
  payload="$(render_xtcp_payload \
    "frps.example.com" \
    "7000" \
    "p2p_ssh" \
    "p2p_ssh_visitor" \
    "secret-key" \
    "127.0.0.1" \
    "6000" \
    "true" \
    "true" \
    "p2p_ssh_stcp" \
    "p2p_ssh_stcp_fallback" \
    "5000" \
    "quic" \
    "true")"

  assert_eq "install-frp-xtcp-v1" "$(parse_xtcp_payload_value "$payload" format)" "xtcp payload format"
  assert_eq "p2p_ssh" "$(parse_xtcp_payload_value "$payload" proxyName)" "xtcp proxy name parsed"

  code="$(encrypt_payload_code "IFRP-XTCP-V1" "passphrase" "$payload")"
  [[ "$code" == IFRP-XTCP-V1:* ]] || fail "xtcp code prefix missing"
  decoded="$(decrypt_payload_code "IFRP-XTCP-V1" "passphrase" "$code")"
  assert_eq "$payload" "$decoded" "xtcp code decrypts to payload"

  exposed_file="${TMP_DIR}/xtcp-exposed.toml"
  write_xtcp_exposed_config "$exposed_file" "p2p_ssh" "secret-key" "127.0.0.1" "22" "true" "p2p_ssh_stcp" "true"
  assert_contains 'type = "xtcp"' "$exposed_file" "xtcp exposed proxy rendered"
  assert_contains '[proxies.natTraversal]' "$exposed_file" "xtcp exposed nat traversal section rendered"
  assert_contains 'name = "p2p_ssh_stcp"' "$exposed_file" "stcp fallback proxy rendered"

  visitor_file="${TMP_DIR}/xtcp-visitor.toml"
  write_xtcp_visitor_config_from_payload "$visitor_file" "$payload"
  assert_contains 'type = "xtcp"' "$visitor_file" "xtcp visitor rendered"
  assert_contains 'protocol = "quic"' "$visitor_file" "xtcp protocol rendered"
  assert_contains 'keepTunnelOpen = true' "$visitor_file" "xtcp keep tunnel open rendered"
  assert_contains 'fallbackTo = "p2p_ssh_stcp_fallback"' "$visitor_file" "xtcp fallback rendered"
  assert_contains 'fallbackTimeoutMs = 5000' "$visitor_file" "xtcp fallback timeout rendered"
  assert_contains '[visitors.natTraversal]' "$visitor_file" "xtcp nat traversal section rendered"
  assert_contains 'disableAssistedAddrs = true' "$visitor_file" "xtcp assisted addresses disabled"
  assert_contains 'bindPort = -1' "$visitor_file" "stcp fallback bind port rendered"

  local old_visitor_file
  old_visitor_file="${TMP_DIR}/old-xtcp-visitor.toml"
  cat > "$old_visitor_file" <<'EOF_OLD_XTCP_VISITOR'
[[visitors]]
name = "p2p_ssh_visitor"
type = "xtcp"
serverName = "p2p_ssh"
secretKey = "secret-key"
bindAddr = "127.0.0.1"
bindPort = 6000
protocol = "quic"
keepTunnelOpen = false
fallbackTo = "p2p_ssh_stcp_fallback"
fallbackTimeoutMs = 200
EOF_OLD_XTCP_VISITOR
  tune_xtcp_config_file "$old_visitor_file" "quic" "true" "5000" "true"
  assert_contains 'protocol = "quic"' "$old_visitor_file" "xtcp repair keeps visitor on quic"
  assert_contains 'keepTunnelOpen = true' "$old_visitor_file" "xtcp repair enables keep tunnel open"
  assert_contains 'fallbackTimeoutMs = 5000' "$old_visitor_file" "xtcp repair raises fallback timeout"
  assert_contains '[visitors.natTraversal]' "$old_visitor_file" "xtcp repair adds visitor nat traversal"

  local summary
  summary="$(render_xtcp_config_summary "$old_visitor_file")"
  assert_contains 'visitor p2p_ssh_visitor' <(printf '%s\n' "$summary") "xtcp summary shows visitor name"
  assert_contains 'protocol=quic' <(printf '%s\n' "$summary") "xtcp summary shows protocol"
  assert_contains 'keepTunnelOpen=true' <(printf '%s\n' "$summary") "xtcp summary shows keepTunnelOpen"
  assert_contains 'disableAssistedAddrs=true' <(printf '%s\n' "$summary") "xtcp summary shows nat traversal"
  declare -f run_cli | grep -Fq -- '--xtcp-summary' || fail "cli should expose xtcp summary"
  declare -f run_cli | grep -Fq -- '--repair-xtcp-file' || fail "cli should expose xtcp repair"
}

test_frps_pairing_code_helpers() {
  require_function render_frpc_pairing_payload
  require_function write_frpc_config_from_pairing_payload
  require_function export_frps_pairing_code
  require_function import_frps_pairing_code

  local payload code decoded config_path split_dir token_path log_path
  payload="$(render_frpc_pairing_payload \
    "frps.example.com" \
    "7000" \
    "server-token#frag" \
    "tcp" \
    "true" \
    "0" \
    "" \
    "new-client")"

  assert_eq "install-frp-frpc-v1" "$(parse_payload_value "$payload" format)" "frps pairing payload format"
  assert_eq "server-token#frag" "$(parse_payload_value "$payload" token)" "frps pairing token parsed"

  code="$(encrypt_payload_code "IFRP-FRPC-V1" "passphrase" "$payload")"
  [[ "$code" == IFRP-FRPC-V1:* ]] || fail "frps pairing code prefix missing"
  decoded="$(decrypt_payload_code "IFRP-FRPC-V1" "passphrase" "$code")"
  assert_eq "$payload" "$decoded" "frps pairing code decrypts to payload"

  config_path="${TMP_DIR}/paired/frpc.toml"
  split_dir="${TMP_DIR}/paired/frpc.d"
  token_path="${TMP_DIR}/paired/token"
  log_path="${TMP_DIR}/paired/frpc.log"
  write_frpc_config_from_pairing_payload "$config_path" "$split_dir" "$token_path" "$log_path" "${TMP_DIR}/paired/store.json" "$payload"
  assert_contains 'serverAddr = "frps.example.com"' "$config_path" "paired frpc server address"
  assert_contains 'auth.tokenSource.file.path = "'"$token_path"'"' "$config_path" "paired frpc token source"
  assert_contains 'server-token#frag' "$token_path" "paired token file"
}

test_install_state_and_status_bar() {
  require_function normalize_version_tag
  require_function binary_version_tag
  require_function installed_frp_version
  require_function should_skip_frp_download
  require_function render_component_status
  require_function render_status_bar
  require_function resolve_default_version
  require_function render_main_menu
  require_function render_frps_menu
  require_function render_frpc_menu
  require_function curl_download
  require_function print_service_summary
  require_function restart_service_if_present
  require_function shell_quote
  require_function render_one_click_import_command
  require_function run_cli

  assert_eq "v0.68.1" "$(normalize_version_tag "0.68.1")" "plain version normalized"
  assert_eq "v0.69.0" "$(normalize_version_tag "frp 0.69.0")" "version text normalized"
  assert_eq "v0.70.0" "$(resolve_default_version "v0.70.0" "v0.68.1" "v0.69.0")" "explicit version wins"
  assert_eq "v0.69.0" "$(resolve_default_version "" "v0.68.1" "v0.69.0")" "latest version wins over installed"
  assert_eq "v0.68.1" "$(resolve_default_version "" "v0.68.1" "")" "installed version used when latest missing"

  mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"
  cat > "${INSTALL_DIR}/frps" <<'EOF_FAKE_FRPS'
#!/usr/bin/env bash
echo "0.68.1"
EOF_FAKE_FRPS
  cat > "${INSTALL_DIR}/frpc" <<'EOF_FAKE_FRPC'
#!/usr/bin/env bash
echo "0.68.1"
EOF_FAKE_FRPC
  chmod +x "${INSTALL_DIR}/frps" "${INSTALL_DIR}/frpc"
  printf 'bindPort = 7000\n' > "$FRPS_CONFIG"
  printf 'serverPort = 7000\n' > "$FRPC_CONFIG"

  assert_eq "v0.68.1" "$(binary_version_tag "${INSTALL_DIR}/frps")" "frps binary version detected"
  assert_eq "v0.68.1" "$(installed_frp_version)" "installed pair version detected"
  should_skip_frp_download "v0.68.1" "n" >/dev/null || fail "same version should skip when reinstall not confirmed"
  ! should_skip_frp_download "v0.69.0" "n" >/dev/null 2>&1 || fail "different version should not skip"
  rm -f "${INSTALL_DIR}/frpc"
  ! should_skip_frp_download "v0.68.1" "n" >/dev/null 2>&1 || fail "partial install should not skip download"
  cat > "${INSTALL_DIR}/frpc" <<'EOF_FAKE_FRPC_RESTORE'
#!/usr/bin/env bash
echo "0.68.1"
EOF_FAKE_FRPC_RESTORE
  chmod +x "${INSTALL_DIR}/frpc"

  local frps_status status_bar
  frps_status="$(render_component_status "frps" "${INSTALL_DIR}/frps" "$FRPS_CONFIG" "frps")"
  [[ "$frps_status" == *"frps: v0.68.1"* ]] || fail "frps status missing version: ${frps_status}"
  [[ "$frps_status" == *"已配置"* ]] || fail "frps status missing config state: ${frps_status}"

  status_bar="$(render_status_bar)"
  [[ "$status_bar" == *"状态："* ]] || fail "status bar missing title"
  [[ "$status_bar" == *"服务端:未运行"* ]] || fail "status bar missing server summary: ${status_bar}"
  [[ "$status_bar" == *"客户端:未运行"* ]] || fail "status bar missing client summary: ${status_bar}"
  [[ "$status_bar" =~ 实例:[0-9]+ ]] || fail "status bar missing instance count: ${status_bar}"
  [[ "$status_bar" != *"v0."* ]] || fail "main status should not show detailed versions: ${status_bar}"
  [[ "$status_bar" != *"已配置"* ]] || fail "main status should not show config details: ${status_bar}"
  [[ "$(printf '%s\n' "$status_bar" | wc -l | tr -d '[:space:]')" == "1" ]] || fail "status bar should be one line"

  local menu
  menu="$(render_main_menu)"
  assert_contains '1) 服务端' <(printf '%s\n' "$menu") "compact menu has server entry"
  assert_contains '5) 工具' <(printf '%s\n' "$menu") "compact menu has tools entry"
  ! printf '%s\n' "$menu" | grep -Fq 'frps ' || fail "main menu should use short labels"
  ! printf '%s\n' "$menu" | grep -Fq 'frpc ' || fail "main menu should use short labels"
  ! printf '%s\n' "$menu" | grep -Fq '10)' || fail "main menu should not expose ten top-level entries"

  local frpc_menu frps_menu
  frpc_menu="$(render_frpc_menu)"
  frps_menu="$(render_frps_menu)"
  assert_contains '1) 安装/更新' <(printf '%s\n' "$frpc_menu") "frpc menu has short install entry"
  assert_contains '2) 启动/停止/重启' <(printf '%s\n' "$frpc_menu") "frpc menu exposes restart management"
  assert_contains '5) 代理配置' <(printf '%s\n' "$frpc_menu") "frpc menu has short proxy entry"
  ! printf '%s\n' "$frpc_menu" | grep -Fq '默认 frpc 客户端' || fail "frpc menu should not repeat long default client text"
  ! printf '%s\n' "$frpc_menu" | grep -Fq 'systemd 服务' || fail "frpc menu should use short service text"
  assert_contains '2) 启动/停止/重启' <(printf '%s\n' "$frps_menu") "frps menu exposes restart management"
  assert_contains '3) 接入码' <(printf '%s\n' "$frps_menu") "frps menu has short pairing entry"
  ! declare -f curl_download | grep -Fq 'curl -fL ' || fail "curl download should be silent and not show progress meter"
  ! grep -Fq 'systemctl --no-pager --full status' "${ROOT_DIR}/frp.sh" || fail "script should not dump full systemd status in normal flow"
  declare -f create_xtcp_exposed_and_code | grep -Fq 'restart_service_if_present "$SELECTED_FRPC_SERVICE"' || fail "xtcp exposed setup should restart/register exposed proxy"

  local import_cmd
  import_cmd="$(render_one_click_import_command "xtcp" "IFRP-XTCP-V1:abc" "pa ss'word")"
  assert_contains '--import-xtcp-code' <(printf '%s\n' "$import_cmd") "xtcp one-click command uses cli import"
  assert_contains "'pa ss'\\''word'" <(printf '%s\n' "$import_cmd") "one-click command quotes passphrase"
  ! printf '%s\n' "$import_cmd" | grep -Fq '/refs/heads/main/' || fail "one-click command should avoid stale refs/heads raw cache"
  declare -f export_frps_pairing_code | grep -Fq 'render_one_click_import_command "frps"' || fail "frps export should print one-click import command"
  declare -f create_xtcp_exposed_and_code | grep -Fq 'render_one_click_import_command "xtcp"' || fail "xtcp export should print one-click import command"

  local restart_output
  if ! restart_output="$( ( has_cmd() { return 1; }; restart_service_if_present frpc ) 2>&1 )"; then
    fail "restart_service_if_present should not fail under set -u when prompt is omitted: ${restart_output}"
  fi
  assert_contains '无法重启 frpc' <(printf '%s\n' "$restart_output") "restart helper handles omitted prompt"
}

main() {
  bash -n "${ROOT_DIR}/frp.sh"
  pass "frp.sh syntax"
  test_instance_helpers_exist
  test_instance_paths
  test_frpc_base_config_renderer
  test_named_instance_lifecycle_helpers
  test_config_edit_helpers
  test_xtcp_import_code_helpers
  test_frps_pairing_code_helpers
  test_install_state_and_status_bar
  printf 'All %d tests passed.\n' "$pass_count"
}

main "$@"
