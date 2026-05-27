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
  require_function render_frpc_instance_list
  require_function render_frpc_template_service
  require_function write_frpc_template_service
  require_function configure_named_frpc_instance
  require_function copy_default_frpc_to_instance
  require_function frps_management_menu
  require_function manage_frpc_instances_menu
  require_function frpc_management_menu

  mkdir -p "${FRPC_CLIENTS_DIR}/home" "${FRPC_CLIENTS_DIR}/company" "${FRPC_CLIENTS_DIR}/empty" "${FRPC_CLIENTS_DIR}/bad name"
  : > "${FRPC_CLIENTS_DIR}/home/frpc.toml"
  : > "${FRPC_CLIENTS_DIR}/company/frpc.toml"
  : > "${FRPC_CLIENTS_DIR}/bad name/frpc.toml"

  assert_eq $'company\nhome' "$(list_frpc_instances)" "named instances listed from configs"
  assert_not_contains 'bad name' <(list_frpc_instances) "invalid instance directory is ignored"
  local rendered_instances
  rendered_instances="$(render_frpc_instance_list)"
  assert_contains 'company' <(printf '%s\n' "$rendered_instances") "rendered instances show company"
  assert_contains 'home' <(printf '%s\n' "$rendered_instances") "rendered instances show home"
  assert_contains 'frpc@home' <(printf '%s\n' "$rendered_instances") "rendered instances show service name"

  local old_clients_dir empty_instances
  old_clients_dir="$FRPC_CLIENTS_DIR"
  FRPC_CLIENTS_DIR="${TMP_DIR}/empty-clients"
  mkdir -p "$FRPC_CLIENTS_DIR"
  empty_instances="$(render_frpc_instance_list)"
  assert_contains '没有命名 frpc 实例' <(printf '%s\n' "$empty_instances") "empty instance list explains next step"
  assert_contains '客户端 -> 实例 -> 新建/重配实例' <(printf '%s\n' "$empty_instances") "empty instance list uses absolute menu path"
  assert_not_contains '选择 2)' <(printf '%s\n' "$empty_instances") "empty instance list avoids relative menu number"
  FRPC_CLIENTS_DIR="$old_clients_dir"

  local service_path="${TMP_DIR}/frpc@.service"
  render_frpc_template_service > "$service_path"
  assert_contains 'Description=frp client instance %i service' "$service_path" "template description"
  assert_contains 'ExecStart='"${INSTALL_DIR}"'/frpc -c '"${FRPC_CLIENTS_DIR}"'/%i/frpc.toml' "$service_path" "template execstart"

  local migrate_root="${TMP_DIR}/copy-default" copy_output instance_config instance_split instance_token instance_store instance_log
  migrate_root="${TMP_DIR}/copy-default"
  instance_config="${migrate_root}/etc/frp/clients/home/frpc.toml"
  instance_split="${migrate_root}/etc/frp/clients/home/frpc.d"
  instance_token="${migrate_root}/etc/frp/clients/home/token"
  instance_store="${migrate_root}/etc/frp/clients/home/frpc-store.json"
  instance_log="${migrate_root}/var/log/frp/frpc-home.log"
  copy_output="$(
    (
      INSTALL_DIR="${migrate_root}/usr/local/bin"
      CONFIG_DIR="${migrate_root}/etc/frp"
      FRPC_CONFIG="${CONFIG_DIR}/frpc.toml"
      FRPC_CONF_DIR="${CONFIG_DIR}/frpc.d"
      FRPC_CLIENTS_DIR="${CONFIG_DIR}/clients"
      PRESET_DIR="${CONFIG_DIR}/presets.d"
      LOG_DIR="${migrate_root}/var/log/frp"
      TOKEN_FILE="${CONFIG_DIR}/token"
      FRPC_STORE="${CONFIG_DIR}/frpc-store.json"
      mkdir -p "$INSTALL_DIR" "$FRPC_CONF_DIR" "$PRESET_DIR" "$LOG_DIR"
      : > "${INSTALL_DIR}/frpc"
      chmod +x "${INSTALL_DIR}/frpc"
      cat > "$FRPC_CONFIG" <<EOF_DEFAULT_FRPC
serverAddr = "frps.example.com"
serverPort = 7000
includes = ["${CONFIG_DIR}/frpc.d/*.toml"]
auth.method = "token"
auth.tokenSource.type = "file"
auth.tokenSource.file.path = "${CONFIG_DIR}/token"
log.to = "${LOG_DIR}/frpc.log"
[store]
path = "${CONFIG_DIR}/frpc-store.json"
EOF_DEFAULT_FRPC
      printf 'secret-token\n' > "$TOKEN_FILE"
      printf '{"proxies":[]}\n' > "$FRPC_STORE"
      printf '[[proxies]]\nname = "ssh"\ntype = "tcp"\nlocalPort = 22\nremotePort = 6000\n' > "${FRPC_CONF_DIR}/ssh.toml"
      ask_required() { printf 'home'; }
      confirm() { [[ "$1" == 是否现在启动* ]]; }
      verify_config() { printf 'verify:%s\n' "$2"; return 0; }
      write_frpc_template_service() { printf 'template-service\n'; }
      systemctl_enable_restart() { SERVICE_ACTION_STATUS=0; printf 'enable-restart:%s\n' "$1"; }
      service_exists() { return 0; }
      service_action() { printf 'service:%s:%s\n' "$1" "$2"; }
      copy_default_frpc_to_instance
    ) 2>&1
  )"
  assert_contains "verify:${instance_config}" <(printf '%s\n' "$copy_output") "copy default frpc verifies named instance"
  assert_contains 'template-service' <(printf '%s\n' "$copy_output") "copy default frpc writes instance template service"
  assert_contains 'enable-restart:frpc@home' <(printf '%s\n' "$copy_output") "copy default frpc starts named instance"
  assert_contains 'serverAddr = "frps.example.com"' "$instance_config" "copy default frpc keeps server address"
  assert_contains 'includes = ["'"${instance_split}"'/*.toml"]' "$instance_config" "copy default frpc rewrites includes"
  assert_contains 'auth.tokenSource.file.path = "'"${instance_token}"'"' "$instance_config" "copy default frpc rewrites token path"
  assert_contains 'log.to = "'"${instance_log}"'"' "$instance_config" "copy default frpc rewrites log path"
  assert_contains 'path = "'"${instance_store}"'"' "$instance_config" "copy default frpc rewrites store path"
  assert_contains 'secret-token' "$instance_token" "copy default frpc copies token file"
  assert_contains 'name = "ssh"' "${instance_split}/ssh.toml" "copy default frpc copies split proxy config"

  local failed_start_output
  failed_start_output="$(
    (
      INSTALL_DIR="${migrate_root}/usr/local/bin"
      CONFIG_DIR="${migrate_root}/etc/frp"
      FRPC_CONFIG="${CONFIG_DIR}/frpc.toml"
      FRPC_CONF_DIR="${CONFIG_DIR}/frpc.d"
      FRPC_CLIENTS_DIR="${CONFIG_DIR}/clients"
      PRESET_DIR="${CONFIG_DIR}/presets.d"
      LOG_DIR="${migrate_root}/var/log/frp"
      TOKEN_FILE="${CONFIG_DIR}/token"
      FRPC_STORE="${CONFIG_DIR}/frpc-store.json"
      ask_required() { printf 'failed'; }
      confirm() { return 0; }
      verify_config() { return 0; }
      write_frpc_template_service() { :; }
      systemctl_enable_restart() { SERVICE_ACTION_STATUS=1; printf 'enable-restart:%s\n' "$1"; }
      service_exists() { [[ "$1" == "frpc" ]]; }
      service_action() { printf 'service:%s:%s\n' "$1" "$2"; }
      copy_default_frpc_to_instance
    ) 2>&1
  )"
  assert_contains 'enable-restart:frpc@failed' <(printf '%s\n' "$failed_start_output") "copy default frpc attempts to start failed named instance"
  assert_not_contains 'service:frpc:stop' <(printf '%s\n' "$failed_start_output") "copy default frpc does not stop default when named instance start fails"
  assert_not_contains 'service:frpc:disable' <(printf '%s\n' "$failed_start_output") "copy default frpc does not disable default when named instance start fails"

  local instance_menu
  instance_menu="$(declare -f manage_frpc_instances_menu)"
  assert_contains '从默认 frpc 复制为实例' <(printf '%s\n' "$instance_menu") "instance menu exposes copy default action"
}

test_config_edit_helpers() {
  require_function choose_editor
  require_function backup_file
  require_function edit_config_file
  require_function choose_frpc_split_config
  require_function show_frpc_split_configs_for_dir
  require_function frps_config_menu
  require_function frpc_config_menu

  local sample="${TMP_DIR}/sample.toml"
  printf 'value = "original"\n' > "$sample"
  local backup
  backup="$(backup_file "$sample")"
  [[ -f "$backup" ]] || fail "backup file was not created"
  assert_contains 'value = "original"' "$backup" "backup content"

  EDITOR="/bin/true"
  assert_eq "/bin/true" "$(choose_editor)" "editor selected from EDITOR"

  local old_clients_dir empty_config_output ask_count_file
  old_clients_dir="$FRPC_CLIENTS_DIR"
  FRPC_CLIENTS_DIR="${TMP_DIR}/empty-config-clients"
  mkdir -p "$FRPC_CLIENTS_DIR"
  ask_count_file="${TMP_DIR}/empty-config-ask-count"
  printf '0' > "$ask_count_file"
  empty_config_output="$(
    (
      ask() {
        local n
        n="$(cat "$ask_count_file")"
        n=$((n + 1))
        printf '%s' "$n" > "$ask_count_file"
        if (( n == 1 )); then printf '2'; else printf '0'; fi
      }
      ask_required() { fail "frpc_config_menu should not ask instance name when no instances exist"; }
      pause() { return 0; }
      frpc_config_menu
    ) 2>&1
  )"
  assert_contains '没有命名 frpc 实例' <(printf '%s\n' "$empty_config_output") "frpc config named instance stops early when no instances exist"
  assert_contains '客户端 -> 实例 -> 新建/重配实例' <(printf '%s\n' "$empty_config_output") "frpc config named instance gives absolute create path"
  FRPC_CLIENTS_DIR="$old_clients_dir"
}

test_verify_config_behavior() {
  require_function verify_config
  require_function verify_config_before_restart

  local conf bin output status
  conf="${TMP_DIR}/verify.toml"
  printf 'serverPort = 7000\n' > "$conf"

  output="$(verify_config "${TMP_DIR}/missing-frpc" "$conf" 2>&1 || true)"
  assert_contains 'frp 可执行文件不存在或不可执行' <(printf '%s\n' "$output") "verify warns for missing binary"

  bin="${TMP_DIR}/frpc-fail"
  cat > "$bin" <<'EOF_VERIFY_FAIL'
#!/usr/bin/env bash
exit 23
EOF_VERIFY_FAIL
  chmod +x "$bin"

  output="$(verify_config "$bin" "${TMP_DIR}/missing.toml" 2>&1 || true)"
  assert_contains '配置文件不存在' <(printf '%s\n' "$output") "verify warns for missing config"

  status=0
  if output="$(verify_config "$bin" "$conf" 2>&1)"; then
    fail "failing verify should return non-zero"
  else
    status=$?
  fi
  assert_eq "23" "$status" "failing verify can be captured by caller"

  local unsafe_calls
  unsafe_calls="$(grep -nF 'verify_config_before_restart' "${ROOT_DIR}/frp.sh" | grep -F '|| return $?' || true)"
  [[ -z "$unsafe_calls" ]] || fail "verify_config_before_restart callers must not return verify status: ${unsafe_calls}"
  pass "verify_config_before_restart callers keep menus alive on verify failure"

  local edit_output edit_status edit_file
  edit_file="${TMP_DIR}/edit-frpc.toml"
  printf 'serverPort = 7000\n' > "$edit_file"
  edit_status=0
  if edit_output="$(
    (
      EDITOR=/bin/true
      verify_config() { return 13; }
      confirm() { return 0; }
      restart_service_if_present() { printf 'restart:%s\n' "$1"; }
      edit_config_file "$edit_file" "测试配置" "$bin" "frpc"
    ) 2>&1
  )"; then
    edit_status=0
  else
    edit_status=$?
  fi
  assert_eq "0" "$edit_status" "edit config returns to menu after verify failure"
  assert_not_contains 'restart:frpc' <(printf '%s\n' "$edit_output") "edit config skips restart after verify failure"
}

test_global_verify_and_logs_cover_instances() {
  require_function verify_all_configs
  require_function show_service_log
  require_function patch_log_config_file

  mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$FRPC_CONF_DIR" "$FRPC_CLIENTS_DIR/home" "$LOG_DIR"
  : > "${INSTALL_DIR}/frps"
  : > "${INSTALL_DIR}/frpc"
  chmod +x "${INSTALL_DIR}/frps" "${INSTALL_DIR}/frpc"
  printf 'bindPort = 7000\n' > "$FRPS_CONFIG"
  printf 'serverPort = 7000\n' > "$FRPC_CONFIG"
  printf 'serverPort = 7000\nlog.to = "%s/frpc-home.log"\n' "$LOG_DIR" > "${FRPC_CLIENTS_DIR}/home/frpc.toml"
  printf 'home log line\n' > "${LOG_DIR}/frpc-home.log"

  local verify_output
  verify_output="$(
    (
      verify_config() { printf 'verify:%s\n' "$2"; }
      verify_all_configs
    ) 2>&1
  )"
  assert_contains "verify:${FRPC_CLIENTS_DIR}/home/frpc.toml" <(printf '%s\n' "$verify_output") "global verify includes named frpc instances"

  local log_output
  log_output="$(show_service_log "frpc@home" "5" "false" 2>&1)"
  assert_contains 'home log line' <(printf '%s\n' "$log_output") "named frpc service log reads instance log file"

  patch_log_config_file "${FRPC_CLIENTS_DIR}/home/frpc.toml" "${LOG_DIR}/frpc-home.log" "frpc@home" >/dev/null
  assert_contains 'log.to = "'"${LOG_DIR}"'/frpc-home.log"' "${FRPC_CLIENTS_DIR}/home/frpc.toml" "log patch supports named frpc config"
}

test_log_fix_all_is_best_effort() {
  require_function fix_log_config_menu
  require_function fix_log_config_target
  require_function select_existing_named_frpc_target

  local case_root="${TMP_DIR}/log-fix-all" output instance_conf instance_log
  instance_conf="${case_root}/etc/frp/clients/home/frpc.toml"
  instance_log="${case_root}/var/log/frp/frpc-home.log"
  output="$(
    (
      INSTALL_DIR="${case_root}/usr/local/bin"
      CONFIG_DIR="${case_root}/etc/frp"
      FRPS_CONFIG="${CONFIG_DIR}/frps.toml"
      FRPC_CONFIG="${CONFIG_DIR}/frpc.toml"
      FRPC_CLIENTS_DIR="${CONFIG_DIR}/clients"
      LOG_DIR="${case_root}/var/log/frp"
      mkdir -p "$INSTALL_DIR" "${FRPC_CLIENTS_DIR}/home" "$LOG_DIR"
      : > "${INSTALL_DIR}/frpc"
      chmod +x "${INSTALL_DIR}/frpc"
      printf 'serverPort = 7000\n' > "$instance_conf"
      ask() { printf '4'; }
      confirm() { return 1; }
      verify_config() { printf 'verify:%s\n' "$2"; return 0; }
      fix_log_config_menu
    ) 2>&1
  )"

  assert_contains "跳过 frps" <(printf '%s\n' "$output") "log repair all skips missing frps without aborting"
  assert_contains "跳过 frpc" <(printf '%s\n' "$output") "log repair all skips missing default frpc without aborting"
  assert_contains "verify:${instance_conf}" <(printf '%s\n' "$output") "log repair all still verifies named instance"
  assert_contains 'log.to = "'"${instance_log}"'"' "$instance_conf" "log repair all patches named instance after skips"

  local fix_log_body
  fix_log_body="$(declare -f fix_log_config_menu)"
  assert_contains 'select_existing_named_frpc_target' <(printf '%s\n' "$fix_log_body") "named log repair does not duplicate default frpc selector"
}

test_frpc_proxy_target_helpers() {
  require_function select_frpc_split_dir_for_write
  require_function with_frpc_write_target
  require_function write_rendered_frpc_config
  require_function render_custom_preset_to_file
  require_function paste_raw_frpc_toml
  require_function add_proxy_manual_wizard
  require_function add_proxy_wizard

  local frps_menu_body frpc_target_body add_proxy_body manage_presets_body write_body preset_body paste_body manual_body
  frps_menu_body="$(declare -f frps_config_menu)"
  frpc_target_body="$(declare -f frpc_config_target_menu_direct)"
  add_proxy_body="$(declare -f add_proxy_wizard)"
  manage_presets_body="$(declare -f manage_custom_presets_menu)"
  write_body="$(declare -f write_rendered_frpc_config)"
  preset_body="$(declare -f render_custom_preset_to_file)"
  paste_body="$(declare -f paste_raw_frpc_toml)"
  manual_body="$(declare -f add_proxy_manual_wizard)"

  assert_contains 'verify_config_interactive "${INSTALL_DIR}/frps" "$FRPS_CONFIG"' <(printf '%s\n' "$frps_menu_body") "frps verify menu catches verify failure"
  assert_contains 'verify_config_interactive "${INSTALL_DIR}/frpc" "$SELECTED_FRPC_CONFIG"' <(printf '%s\n' "$frpc_target_body") "frpc verify menu catches verify failure"
  assert_not_contains 'select_frpc_split_dir_for_write || return 0' <(printf '%s\n' "$add_proxy_body") "proxy wizard does not choose target on entry"
  assert_contains 'with_frpc_write_target apply_custom_preset' <(printf '%s\n' "$add_proxy_body") "proxy wizard chooses target before applying preset"
  assert_contains 'manage_custom_presets_menu' <(printf '%s\n' "$add_proxy_body") "proxy wizard manages presets without selecting target"
  assert_contains 'with_frpc_write_target add_proxy_manual_wizard' <(printf '%s\n' "$add_proxy_body") "proxy wizard chooses target before manual write"
  assert_contains 'with_frpc_write_target paste_raw_frpc_toml' <(printf '%s\n' "$add_proxy_body") "proxy wizard chooses target before raw toml write"
  assert_not_contains 'with_frpc_write_target apply_custom_preset' <(printf '%s\n' "$manage_presets_body") "preset management does not duplicate apply action"
  assert_not_contains 'with_frpc_write_target paste_raw_frpc_toml' <(printf '%s\n' "$manage_presets_body") "preset management does not duplicate raw toml action"

  assert_contains 'SELECTED_FRPC_SPLIT_DIR' <(printf '%s\n' "$write_body") "rendered writer creates selected split dir"
  assert_contains 'SELECTED_FRPC_CONFIG' <(printf '%s\n' "$write_body") "rendered writer verifies selected main config"
  assert_contains 'SELECTED_FRPC_SERVICE' <(printf '%s\n' "$write_body") "rendered writer restarts selected service"
  assert_not_contains 'restart_service_if_present frpc' <(printf '%s\n' "$write_body") "rendered writer does not hard-code default service"

  assert_contains 'SELECTED_FRPC_SPLIT_DIR' <(printf '%s\n' "$preset_body") "custom preset writes selected split dir"
  assert_contains 'SELECTED_FRPC_SPLIT_DIR' <(printf '%s\n' "$paste_body") "raw toml writes selected split dir"
  assert_contains 'SELECTED_FRPC_SPLIT_DIR' <(printf '%s\n' "$manual_body") "manual wizard writes selected split dir"
  assert_contains 'SELECTED_FRPC_CONFIG' <(printf '%s\n' "$manual_body") "manual wizard verifies selected main config"
  assert_contains 'SELECTED_FRPC_SERVICE' <(printf '%s\n' "$manual_body") "manual wizard restarts selected service"

  assert_not_contains 'xtcp-visitor' <(printf '%s\n' "$manual_body") "manual wizard does not expose xtcp visitor"
  assert_not_contains 'stcp|xtcp|sudp' <(printf '%s\n' "$manual_body") "manual wizard does not accept xtcp proxy"
  assert_contains 'stcp sudp stcp-visitor sudp-visitor' <(printf '%s\n' "$manual_body") "manual wizard keeps stcp and sudp proxy types"

  local missing_output
  missing_output="$(
    (
      ask() { printf '2'; }
      ask_required() { printf 'ghost'; }
      FRPC_CLIENTS_DIR="${TMP_DIR}/clients-missing"
      if select_frpc_split_dir_for_write; then
        exit 99
      fi
    ) 2>&1
  )"
  assert_contains '命名 frpc 实例主配置不存在' <(printf '%s\n' "$missing_output") "missing named instance warns before split dir write"
  [[ ! -d "${TMP_DIR}/clients-missing/ghost/frpc.d" ]] || fail "missing named instance should not create orphan split dir"
  pass "missing named instance does not create orphan split dir"

  local tmpfile output_file write_output write_status
  mkdir -p "${TMP_DIR}/selected-frpc.d"
  printf 'serverPort = 7000\n' > "${TMP_DIR}/selected-frpc.toml"
  tmpfile="${TMP_DIR}/proxy.toml"
  output_file="${TMP_DIR}/selected-frpc.d/proxy.toml"
  printf '[[proxies]]\nname = "proxy"\ntype = "tcp"\n' > "$tmpfile"
  write_status=0
  if write_output="$(
    (
      SELECTED_FRPC_CONFIG="${TMP_DIR}/selected-frpc.toml"
      SELECTED_FRPC_SPLIT_DIR="${TMP_DIR}/selected-frpc.d"
      SELECTED_FRPC_SERVICE="frpc@selected"
      verify_config() { printf 'verify:%s\n' "$2"; return 7; }
      restart_service_if_present() { printf 'restart:%s\n' "$1"; }
      write_rendered_frpc_config "$output_file" "$tmpfile"
    ) 2>&1
  )"; then
    write_status=0
  else
    write_status=$?
  fi
  assert_eq "0" "$write_status" "rendered writer returns success when selected config fails verify"
  assert_contains "verify:${TMP_DIR}/selected-frpc.toml" <(printf '%s\n' "$write_output") "rendered writer verifies selected config"
  assert_not_contains 'restart:frpc@selected' <(printf '%s\n' "$write_output") "rendered writer skips restart after verify failure"
}

test_import_targets_and_safe_failures() {
  require_function render_one_click_import_command
  require_function import_frps_pairing_code
  require_function import_xtcp_code_to_visitor
  require_function service_action
  require_function systemctl_enable_restart
  require_function restart_service_if_present

  local import_cmd
  import_cmd="$(render_one_click_import_command "frps" "IFRP-FRPC-V1:abc" "pass phrase")"
  assert_contains "'default'" <(printf '%s\n' "$import_cmd") "one-click import command carries explicit default target"

  local bad_output bad_status
  bad_status=0
  if bad_output="$(import_frps_pairing_code "bad-code" "bad-pass" "false" "default" 2>&1)"; then
    bad_status=0
  else
    bad_status=$?
  fi
  assert_eq "0" "$bad_status" "interactive frps import decode failure returns to menu"
  assert_contains '解密失败' <(printf '%s\n' "$bad_output") "interactive frps import explains decode failure"

  bad_status=0
  if bad_output="$(import_xtcp_code_to_visitor "bad-code" "bad-pass" "true" "default" 2>&1)"; then
    fail "strict xtcp import decode failure should return non-zero"
  else
    bad_status=$?
  fi
  assert_eq "1" "$bad_status" "strict xtcp import decode failure returns non-zero"
  assert_contains '解密失败' <(printf '%s\n' "$bad_output") "strict xtcp import explains decode failure"

  local service_output
  service_output="$(
    (
      has_cmd() { [[ "$1" == "systemctl" ]]; }
      service_exists() { return 0; }
      systemctl() {
        case "$1" in
          list-unit-files|is-active|is-enabled|show) return 0 ;;
          *) return 9 ;;
        esac
      }
      service_action frpc restart false
      systemctl_enable_restart frpc
    ) 2>&1
  )"
  assert_contains '执行失败' <(printf '%s\n' "$service_output") "systemctl failures warn instead of exiting"

  local missing_systemd_output
  missing_systemd_output="$(
    (
      has_cmd() { return 1; }
      print_service_summary() { printf 'summary:%s\n' "$1"; }
      systemctl_enable_restart frpc
    ) 2>&1
  )"
  assert_contains '无法管理 frpc' <(printf '%s\n' "$missing_systemd_output") "enable restart reports missing systemctl"
  assert_not_contains '已启动并设置开机自启' <(printf '%s\n' "$missing_systemd_output") "enable restart does not claim success without systemctl"

  local inactive_output
  inactive_output="$(
    (
      has_cmd() { [[ "$1" == "systemctl" ]]; }
      service_exists() { return 0; }
      systemctl() {
        case "$1" in
          enable|restart|list-unit-files|is-enabled|show) return 0 ;;
          is-active) return 3 ;;
          *) return 0 ;;
        esac
      }
      systemctl_enable_restart frpc
      printf 'status:%s\n' "$SERVICE_ACTION_STATUS"
    ) 2>&1
  )"
  assert_contains '未处于 active 状态' <(printf '%s\n' "$inactive_output") "enable restart checks service active state"
  assert_contains 'status:1' <(printf '%s\n' "$inactive_output") "enable restart marks inactive service as failed"
  assert_not_contains '已启动并设置开机自启' <(printf '%s\n' "$inactive_output") "enable restart does not claim success for inactive service"

  local cli_status cli_output
  cli_status=0
  if cli_output="$(
    (
      need_root() { return 0; }
      has_cmd() { [[ "$1" == "systemctl" ]]; }
      service_exists() { return 0; }
      systemctl() {
        case "$1" in
          list-unit-files|is-active|is-enabled|show) return 0 ;;
          restart) return 9 ;;
          *) return 0 ;;
        esac
      }
      run_cli --service frpc restart
    ) 2>&1
  )"; then
    fail "cli service restart should return non-zero on systemctl failure"
  else
    cli_status=$?
  fi
  assert_eq "1" "$cli_status" "cli service restart returns non-zero on systemctl failure"
  assert_contains '执行失败' <(printf '%s\n' "$cli_output") "cli service restart explains failure"

  local restart_output
  restart_output="$(
    (
      has_cmd() { [[ "$1" == "systemctl" ]]; }
      service_exists() { return 0; }
      confirm() { return 0; }
      systemctl() {
        case "$1" in
          list-unit-files|is-active|is-enabled|show) return 0 ;;
          restart) return 9 ;;
          *) return 0 ;;
        esac
      }
      print_service_summary() { printf 'summary:%s\n' "$1"; }
      restart_service_if_present frpc "restart?" "Y"
    ) 2>&1
  )"
  assert_contains '重启失败' <(printf '%s\n' "$restart_output") "restart helper reports service restart failure"
  assert_not_contains '已重启' <(printf '%s\n' "$restart_output") "restart helper does not claim success after failure"

  (
    has_cmd() { [[ "$1" == "systemctl" ]]; }
    systemctl() {
      [[ "$1" == "list-unit-files" && "$2" == "frpc@.service" ]]
    }
    service_exists frpc@cmcc
  ) || fail "templated frpc@ instance should exist when frpc@.service exists"
  pass "templated frpc@ instance service is detected from template unit"

  (
    has_cmd() { [[ "$1" == "systemctl" ]]; }
    systemctl() {
      [[ "$1" == "list-unit-files" && "$2" == "foo@.service" ]]
    }
    ! service_exists foo@bar
  ) || fail "non-frpc templated services should not be detected from arbitrary templates"
  pass "service_exists only uses template fallback for frpc@ instances"

  local pair_payload pair_code xtcp_payload xtcp_code existing_output existing_status
  pair_payload="$(render_frpc_pairing_payload "frps.example.com" "7000" "token" "tcp" "true" "0" "" "")"
  pair_code="$(encrypt_payload_code "IFRP-FRPC-V1" "passphrase" "$pair_payload")"
  existing_status=0
  if existing_output="$(
    (
      CONFIG_DIR="${TMP_DIR}/existing-frps"
      FRPC_CONFIG="${CONFIG_DIR}/frpc.toml"
      FRPC_CONF_DIR="${CONFIG_DIR}/frpc.d"
      FRPC_CLIENTS_DIR="${CONFIG_DIR}/clients"
      PRESET_DIR="${CONFIG_DIR}/presets.d"
      LOG_DIR="${CONFIG_DIR}/logs"
      TOKEN_FILE="${CONFIG_DIR}/token"
      FRPC_STORE="${CONFIG_DIR}/frpc-store.json"
      create_dirs_and_user() { mkdir -p "$CONFIG_DIR" "$FRPC_CONF_DIR" "$FRPC_CLIENTS_DIR" "$PRESET_DIR" "$LOG_DIR"; printf 'old\n' > "$FRPC_CONFIG"; }
      confirm() { return 1; }
      verify_config() { printf 'unexpected verify\n'; return 0; }
      restart_service_if_present() { printf 'unexpected restart\n'; }
      import_frps_pairing_code "$pair_code" "passphrase" "true" "default"
    ) 2>&1
  )"; then
    fail "strict frps import should fail when existing target is not overwritten"
  else
    existing_status=$?
  fi
  assert_eq "1" "$existing_status" "strict frps import returns non-zero when overwrite is declined"
  assert_contains '已取消覆盖' <(printf '%s\n' "$existing_output") "strict frps import reports declined overwrite"

  xtcp_payload="$(render_xtcp_payload "frps.example.com" "7000" "p2p_ssh" "p2p_ssh_visitor" "secret" "127.0.0.1" "6000" "true" "false" "" "" "5000" "quic" "false" "" "")"
  xtcp_code="$(encrypt_payload_code "IFRP-XTCP-V1" "passphrase" "$xtcp_payload")"
  existing_status=0
  if existing_output="$(
    (
      CONFIG_DIR="${TMP_DIR}/existing-xtcp"
      FRPC_CONFIG="${CONFIG_DIR}/frpc.toml"
      FRPC_CONF_DIR="${CONFIG_DIR}/frpc.d"
      FRPC_CLIENTS_DIR="${CONFIG_DIR}/clients"
      PRESET_DIR="${CONFIG_DIR}/presets.d"
      LOG_DIR="${CONFIG_DIR}/logs"
      create_dirs_and_user() { mkdir -p "$CONFIG_DIR" "$FRPC_CONF_DIR" "$FRPC_CLIENTS_DIR" "$PRESET_DIR" "$LOG_DIR"; : > "$FRPC_CONFIG"; printf 'old\n' > "${FRPC_CONF_DIR}/p2p_ssh_visitor.toml"; }
      confirm() { return 1; }
      verify_config() { printf 'unexpected verify\n'; return 0; }
      restart_service_if_present() { printf 'unexpected restart\n'; }
      import_xtcp_code_to_visitor "$xtcp_code" "passphrase" "true" "default"
    ) 2>&1
  )"; then
    fail "strict xtcp import should fail when existing target is not overwritten"
  else
    existing_status=$?
  fi
  assert_eq "1" "$existing_status" "strict xtcp import returns non-zero when overwrite is declined"
  assert_contains '已取消覆盖' <(printf '%s\n' "$existing_output") "strict xtcp import reports declined overwrite"

  existing_status=0
  if existing_output="$(import_frps_pairing_code "$pair_code" "passphrase" "true" "instance" 2>&1)"; then
    fail "strict frps import should reject bare instance target"
  else
    existing_status=$?
  fi
  assert_eq "1" "$existing_status" "strict frps import rejects bare instance target"
  assert_contains 'instance:<name>' <(printf '%s\n' "$existing_output") "bare instance target explains required syntax"

  existing_status=0
  if existing_output="$(import_xtcp_code_to_visitor "$xtcp_code" "passphrase" "true" "instance" 2>&1)"; then
    fail "strict xtcp import should reject bare instance target"
  else
    existing_status=$?
  fi
  assert_eq "1" "$existing_status" "strict xtcp import rejects bare instance target"
  assert_contains 'instance:<name>' <(printf '%s\n' "$existing_output") "bare xtcp instance target explains required syntax"
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
  require_function list_xtcp_config_files
  require_function render_xtcp_path_summary
  require_function repair_xtcp_path
  require_function xtcp_config_check_menu
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
    "true" \
    "remote-user" \
    "*")"

  assert_eq "install-frp-xtcp-v1" "$(parse_xtcp_payload_value "$payload" format)" "xtcp payload format"
  assert_eq "p2p_ssh" "$(parse_xtcp_payload_value "$payload" proxyName)" "xtcp proxy name parsed"
  assert_eq "remote-user" "$(parse_xtcp_payload_value "$payload" serverUser)" "xtcp server user parsed"
  assert_eq "*" "$(parse_xtcp_payload_value "$payload" allowUsers)" "xtcp allow users parsed"

  code="$(encrypt_payload_code "IFRP-XTCP-V1" "passphrase" "$payload")"
  [[ "$code" == IFRP-XTCP-V1:* ]] || fail "xtcp code prefix missing"
  decoded="$(decrypt_payload_code "IFRP-XTCP-V1" "passphrase" "$code")"
  assert_eq "$payload" "$decoded" "xtcp code decrypts to payload"

  exposed_file="${TMP_DIR}/xtcp-exposed.toml"
  write_xtcp_exposed_config "$exposed_file" "p2p_ssh" "secret-key" "127.0.0.1" "22" "true" "p2p_ssh_stcp" "true" "*"
  assert_contains 'type = "xtcp"' "$exposed_file" "xtcp exposed proxy rendered"
  assert_contains '[proxies.natTraversal]' "$exposed_file" "xtcp exposed nat traversal section rendered"
  assert_contains 'name = "p2p_ssh_stcp"' "$exposed_file" "stcp fallback proxy rendered"
  assert_contains 'allowUsers = ["*"]' "$exposed_file" "xtcp exposed allow users rendered"

  visitor_file="${TMP_DIR}/xtcp-visitor.toml"
  write_xtcp_visitor_config_from_payload "$visitor_file" "$payload"
  assert_contains 'type = "xtcp"' "$visitor_file" "xtcp visitor rendered"
  assert_contains 'protocol = "quic"' "$visitor_file" "xtcp protocol rendered"
  assert_contains 'keepTunnelOpen = true' "$visitor_file" "xtcp keep tunnel open rendered"
  assert_contains 'fallbackTo = "p2p_ssh_stcp_fallback"' "$visitor_file" "xtcp fallback rendered"
  assert_contains 'fallbackTimeoutMs = 5000' "$visitor_file" "xtcp fallback timeout rendered"
  assert_contains 'serverUser = "remote-user"' "$visitor_file" "xtcp visitor server user rendered"
  assert_contains '[visitors.natTraversal]' "$visitor_file" "xtcp nat traversal section rendered"
  assert_contains 'disableAssistedAddrs = true' "$visitor_file" "xtcp assisted addresses disabled"
  assert_contains 'bindPort = -1' "$visitor_file" "stcp fallback bind port rendered"

  local strict_output strict_status
  strict_status=0
  if strict_output="$(
    (
      CONFIG_DIR="${TMP_DIR}/strict-xtcp"
      FRPC_CONFIG="${CONFIG_DIR}/frpc.toml"
      FRPC_CONF_DIR="${CONFIG_DIR}/frpc.d"
      FRPC_CLIENTS_DIR="${CONFIG_DIR}/clients"
      PRESET_DIR="${CONFIG_DIR}/presets.d"
      LOG_DIR="${CONFIG_DIR}/logs"
      create_dirs_and_user() { mkdir -p "$CONFIG_DIR" "$FRPC_CONF_DIR" "$FRPC_CLIENTS_DIR" "$PRESET_DIR" "$LOG_DIR"; : > "$FRPC_CONFIG"; }
      ask() { printf '1'; }
      confirm() { return 0; }
      verify_config() { printf 'verify:%s\n' "$2"; return 19; }
      restart_service_if_present() { printf 'restart:%s\n' "$1"; }
      import_xtcp_code_to_visitor "$code" "passphrase" "true" "default"
    ) 2>&1
  )"; then
    fail "strict xtcp import should return verify failure"
  else
    strict_status=$?
  fi
  assert_eq "19" "$strict_status" "strict xtcp import returns verify failure"
  assert_contains "verify:${TMP_DIR}/strict-xtcp/frpc.toml" <(printf '%s\n' "$strict_output") "strict xtcp import verifies selected config"
  assert_not_contains 'restart:frpc' <(printf '%s\n' "$strict_output") "strict xtcp import skips restart after verify failure"

  local instance_root="${TMP_DIR}/xtcp-instance" instance_output
  instance_output="$(
    (
      CONFIG_DIR="${instance_root}/etc/frp"
      FRPC_CONFIG="${CONFIG_DIR}/frpc.toml"
      FRPC_CONF_DIR="${CONFIG_DIR}/frpc.d"
      FRPC_CLIENTS_DIR="${CONFIG_DIR}/clients"
      PRESET_DIR="${CONFIG_DIR}/presets.d"
      LOG_DIR="${instance_root}/var/log/frp"
      create_dirs_and_user() {
        mkdir -p "$CONFIG_DIR" "$FRPC_CONF_DIR" "${FRPC_CLIENTS_DIR}/home/frpc.d" "$PRESET_DIR" "$LOG_DIR"
        : > "${FRPC_CLIENTS_DIR}/home/frpc.toml"
      }
      verify_config() { printf 'verify:%s\n' "$2"; return 0; }
      restart_service_if_present() { printf 'restart:%s\n' "$1"; }
      import_xtcp_code_to_visitor "$code" "passphrase" "true" "instance:home"
    ) 2>&1
  )"
  assert_contains "verify:${instance_root}/etc/frp/clients/home/frpc.toml" <(printf '%s\n' "$instance_output") "strict xtcp import verifies named instance config"
  assert_contains 'type = "xtcp"' "${instance_root}/etc/frp/clients/home/frpc.d/p2p_ssh_visitor.toml" "strict xtcp import writes named instance visitor"
  assert_contains 'restart:frpc@home' <(printf '%s\n' "$instance_output") "strict xtcp import restarts named instance"

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

  local xtcp_dir dir_summary xtcp_menu_body
  xtcp_dir="${TMP_DIR}/xtcp-dir"
  mkdir -p "$xtcp_dir"
  cp "$old_visitor_file" "${xtcp_dir}/p2p_ssh_visitor.toml"
  printf '[[proxies]]\nname = "plain_tcp"\ntype = "tcp"\n' > "${xtcp_dir}/plain.toml"
  assert_eq "${xtcp_dir}/p2p_ssh_visitor.toml" "$(list_xtcp_config_files "$xtcp_dir")" "xtcp files listed from dir"
  dir_summary="$(render_xtcp_path_summary "$xtcp_dir")"
  assert_contains 'p2p_ssh_visitor.toml' <(printf '%s\n' "$dir_summary") "xtcp dir summary shows file name"
  repair_xtcp_path "$xtcp_dir" "quic" "true" "5000" >/dev/null
  assert_contains 'keepTunnelOpen = true' "${xtcp_dir}/p2p_ssh_visitor.toml" "xtcp dir repair keeps tunnel open"

  xtcp_menu_body="$(declare -f xtcp_pair_menu)"
  assert_contains 'ui_menu_item 3 "检查/修复现有配置"' <(printf '%s\n' "$xtcp_menu_body") "xtcp menu uses unified check entry"
  assert_not_contains '4) 查看 XTCP 配置摘要' <(printf '%s\n' "$xtcp_menu_body") "xtcp menu removes separate summary entry"
  assert_not_contains 'repair_xtcp_config_menu' <(printf '%s\n' "$xtcp_menu_body") "xtcp menu removes single-file repair path"
  assert_not_contains 'show_xtcp_config_summary_menu' <(printf '%s\n' "$xtcp_menu_body") "xtcp menu removes single-file summary path"
  declare -f run_cli | grep -Fq -- '--xtcp-summary' || fail "cli should expose xtcp summary"
  declare -f run_cli | grep -Fq -- '--repair-xtcp' || fail "cli should expose xtcp repair"
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

  local export_root="${TMP_DIR}/export-frps" export_output
  export_output="$(
    (
      CONFIG_DIR="${export_root}/etc/frp"
      FRPS_CONFIG="${CONFIG_DIR}/frps.toml"
      TOKEN_FILE="${CONFIG_DIR}/token"
      LOG_DIR="${export_root}/var/log/frp"
      mkdir -p "$CONFIG_DIR" "$LOG_DIR"
      printf 'server-token#frag\n' > "$TOKEN_FILE"
      printf 'bindPort = 7000\nkcpBindPort = 7000\nquicBindPort = 7001\n' > "$FRPS_CONFIG"
      create_dirs_and_user() { mkdir -p "$CONFIG_DIR" "$LOG_DIR"; }
      ask_required() { printf 'frps.example.com'; }
      ask() {
        printf 'ask:%s:%s\n' "$1" "${2:-}" >&2
        case "$1" in
          *transport.protocol*) printf 'quic' ;;
          *端口*) printf '%s' "$2" ;;
          *连接池*) printf '0' ;;
          *DNS*) printf '' ;;
          *user*) printf '' ;;
          *口令*) printf 'passphrase' ;;
          *) printf '%s' "${2:-}" ;;
        esac
      }
      confirm() { return 0; }
      encrypt_payload_code() { printf 'IFRP-FRPC-V1:test'; printf '\npayload:%s\n' "$3" >&2; }
      export_frps_pairing_code
    ) 2>&1
  )"
  assert_contains 'ask:新客户端连接的 frps 端口；quic 对应端口:7001' <(printf '%s\n' "$export_output") "frps export defaults quic pairing port to quicBindPort"
  assert_contains 'transportProtocol = "quic"' <(printf '%s\n' "$export_output") "frps export pairing payload keeps selected quic protocol"
  assert_contains 'serverPort = 7001' <(printf '%s\n' "$export_output") "frps export pairing payload uses quicBindPort"

  local import_output import_status
  import_status=0
  if import_output="$(
    (
      CONFIG_DIR="${TMP_DIR}/strict-frps"
      FRPC_CONFIG="${CONFIG_DIR}/frpc.toml"
      FRPC_CONF_DIR="${CONFIG_DIR}/frpc.d"
      FRPC_CLIENTS_DIR="${CONFIG_DIR}/clients"
      PRESET_DIR="${CONFIG_DIR}/presets.d"
      LOG_DIR="${CONFIG_DIR}/logs"
      TOKEN_FILE="${CONFIG_DIR}/token"
      FRPC_STORE="${CONFIG_DIR}/frpc-store.json"
      create_dirs_and_user() { mkdir -p "$CONFIG_DIR" "$FRPC_CONF_DIR" "$FRPC_CLIENTS_DIR" "$PRESET_DIR" "$LOG_DIR"; }
      ask() { printf '1'; }
      confirm() { return 0; }
      verify_config() { printf 'verify:%s\n' "$2"; return 17; }
      restart_service_if_present() { printf 'restart:%s\n' "$1"; }
      import_frps_pairing_code "$code" "passphrase" "true" "default"
    ) 2>&1
  )"; then
    fail "strict frps pairing import should return verify failure"
  else
    import_status=$?
  fi
  assert_eq "17" "$import_status" "strict frps import returns verify failure"
  assert_contains "verify:${TMP_DIR}/strict-frps/frpc.toml" <(printf '%s\n' "$import_output") "strict frps import verifies target config"
  assert_not_contains 'restart:frpc' <(printf '%s\n' "$import_output") "strict frps import skips restart after verify failure"

  local instance_root="${TMP_DIR}/pair-instance" instance_output
  instance_output="$(
    (
      CONFIG_DIR="${instance_root}/etc/frp"
      FRPC_CONFIG="${CONFIG_DIR}/frpc.toml"
      FRPC_CONF_DIR="${CONFIG_DIR}/frpc.d"
      FRPC_CLIENTS_DIR="${CONFIG_DIR}/clients"
      PRESET_DIR="${CONFIG_DIR}/presets.d"
      LOG_DIR="${instance_root}/var/log/frp"
      TOKEN_FILE="${CONFIG_DIR}/token"
      FRPC_STORE="${CONFIG_DIR}/frpc-store.json"
      create_dirs_and_user() { mkdir -p "$CONFIG_DIR" "$FRPC_CONF_DIR" "$FRPC_CLIENTS_DIR" "$PRESET_DIR" "$LOG_DIR"; }
      write_frpc_template_service() { printf 'template-service\n'; }
      verify_config() { printf 'verify:%s\n' "$2"; return 0; }
      restart_service_if_present() { printf 'restart:%s\n' "$1"; }
      import_frps_pairing_code "$code" "passphrase" "true" "instance:home"
    ) 2>&1
  )"
  assert_contains "verify:${instance_root}/etc/frp/clients/home/frpc.toml" <(printf '%s\n' "$instance_output") "strict frps import verifies named instance config"
  assert_contains 'serverAddr = "frps.example.com"' "${instance_root}/etc/frp/clients/home/frpc.toml" "strict frps import writes named instance config"
  assert_contains 'server-token#frag' "${instance_root}/etc/frp/clients/home/token" "strict frps import writes named instance token"
  assert_contains 'log.to = "'"${instance_root}"'/var/log/frp/frpc-home.log"' "${instance_root}/etc/frp/clients/home/frpc.toml" "strict frps import writes named instance log path"
}

test_install_state_and_status_bar() {
  require_function normalize_version_tag
  require_function binary_version_tag
  require_function installed_frp_version
  require_function should_skip_frp_download
  require_function render_component_status
  require_function render_status_bar
  require_function frpc_client_status_counts
  require_function ui_client_count_state
  require_function resolve_default_version
  require_function render_main_menu
  require_function render_frps_menu
  require_function render_frpc_menu
  require_function ui_rule
  require_function ui_header
  require_function ui_menu_item
  require_function ui_menu_back
  require_function ui_state
  require_function ui_service_state
  require_function curl_download
  require_function service_exists
  require_function service_action
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

  status_bar="$(
    (
      FRPC_CLIENTS_DIR="${TMP_DIR}/status-bar-none"
      mkdir -p "$FRPC_CLIENTS_DIR"
      has_cmd() { [[ "$1" == "systemctl" ]]; }
      service_exists() { return 1; }
      systemctl() { printf 'inactive\n'; }
      render_status_bar
    )
  )"
  [[ "$status_bar" == *"状态："* ]] || fail "status bar missing title"
  [[ "$status_bar" == *"服务端:未运行"* ]] || fail "status bar missing server summary: ${status_bar}"
  [[ "$status_bar" == *"客户端:1个/运行0"* ]] || fail "status bar missing default client count: ${status_bar}"
  [[ "$status_bar" != *"默认客户端"* ]] || fail "status bar should not expose default client wording: ${status_bar}"
  [[ "$status_bar" != *"命名实例"* ]] || fail "status bar should not expose instance wording: ${status_bar}"
  [[ "$status_bar" != *"v0."* ]] || fail "main status should not show detailed versions: ${status_bar}"
  [[ "$status_bar" != *"已配置"* ]] || fail "main status should not show config details: ${status_bar}"
  [[ "$(printf '%s\n' "$status_bar" | wc -l | tr -d '[:space:]')" == "1" ]] || fail "status bar should be one line"

  status_bar="$(
    (
      FRPC_CLIENTS_DIR="${TMP_DIR}/status-bar-running"
      mkdir -p "${FRPC_CLIENTS_DIR}/home"
      printf 'serverPort = 7000\n' > "${FRPC_CLIENTS_DIR}/home/frpc.toml"
      has_cmd() { [[ "$1" == "systemctl" ]]; }
      service_exists() { [[ "$1" == "frpc@home" ]]; }
      systemctl() {
        if [[ "$1" == "is-active" && "$2" == "frpc@home" ]]; then
          printf 'active\n'
        else
          printf 'inactive\n'
        fi
      }
      render_status_bar
    )
  )"
  [[ "$status_bar" == *"客户端:2个/运行1"* ]] || fail "status bar should aggregate default and running named clients: ${status_bar}"
  [[ "$status_bar" != *"默认客户端"* ]] || fail "status bar should not split default client from named clients: ${status_bar}"
  [[ "$status_bar" != *"命名实例"* ]] || fail "status bar should use client wording for named clients: ${status_bar}"

  status_bar="$(
    (
      FRPC_CLIENTS_DIR="${TMP_DIR}/status-bar-failed"
      mkdir -p "${FRPC_CLIENTS_DIR}/home" "${FRPC_CLIENTS_DIR}/edge"
      printf 'serverPort = 7000\n' > "${FRPC_CLIENTS_DIR}/home/frpc.toml"
      printf 'serverPort = 7000\n' > "${FRPC_CLIENTS_DIR}/edge/frpc.toml"
      has_cmd() { [[ "$1" == "systemctl" ]]; }
      service_exists() { [[ "$1" == frpc@* ]]; }
      systemctl() {
        case "$2" in
          frpc@home) printf 'active\n' ;;
          frpc@edge) printf 'failed\n' ;;
          *) printf 'inactive\n' ;;
        esac
      }
      render_status_bar
    )
  )"
  [[ "$status_bar" == *"客户端:3个/运行1/异常1"* ]] || fail "status bar should aggregate failed named clients: ${status_bar}"

  status_bar="$(
    (
      FRPC_CLIENTS_DIR="${TMP_DIR}/status-bar-default-active"
      mkdir -p "$FRPC_CLIENTS_DIR"
      has_cmd() { [[ "$1" == "systemctl" ]]; }
      service_exists() { [[ "$1" == "frpc" ]]; }
      systemctl() {
        if [[ "$1" == "is-active" && "$2" == "frpc" ]]; then
          printf 'active\n'
        else
          printf 'inactive\n'
        fi
      }
      render_status_bar
    )
  )"
  [[ "$status_bar" == *"客户端:1个/运行1"* ]] || fail "status bar should count running default frpc: ${status_bar}"

  status_bar="$(
    (
      FRPC_CLIENTS_DIR="${TMP_DIR}/status-bar-default-failed"
      mkdir -p "$FRPC_CLIENTS_DIR"
      has_cmd() { [[ "$1" == "systemctl" ]]; }
      service_exists() { [[ "$1" == "frpc" ]]; }
      systemctl() {
        if [[ "$1" == "is-active" && "$2" == "frpc" ]]; then
          printf 'failed\n'
        else
          printf 'inactive\n'
        fi
      }
      render_status_bar
    )
  )"
  [[ "$status_bar" == *"客户端:1个/运行0/异常1"* ]] || fail "status bar should count failed default frpc: ${status_bar}"

  local menu
  menu="$(render_main_menu)"
  assert_contains '1) 服务端' <(printf '%s\n' "$menu") "compact menu has server entry"
  assert_contains '3) 工具/维护' <(printf '%s\n' "$menu") "compact menu has tools entry"
  ! printf '%s\n' "$menu" | grep -Eq '^3\) 配置$' || fail "main menu should not duplicate config entry"
  ! printf '%s\n' "$menu" | grep -Eq '^4\) 日志$' || fail "main menu should not duplicate logs entry"
  ! printf '%s\n' "$menu" | grep -Fq '5)' || fail "main menu should have only three top-level entries"
  ! printf '%s\n' "$menu" | grep -Fq '10)' || fail "main menu should not expose ten top-level entries"

  local frpc_menu frps_menu
  frpc_menu="$(render_frpc_menu)"
  frps_menu="$(render_frps_menu)"
  assert_contains '1) 安装/更新' <(printf '%s\n' "$frpc_menu") "frpc menu has short install entry"
  assert_contains '2) 服务管理' <(printf '%s\n' "$frpc_menu") "frpc menu exposes service management"
  assert_contains '5) 代理配置' <(printf '%s\n' "$frpc_menu") "frpc menu has short proxy entry"
  assert_contains '7) 配置' <(printf '%s\n' "$frpc_menu") "frpc menu groups view edit verify config"
  ! printf '%s\n' "$frpc_menu" | grep -Fq '9)' || fail "frpc menu should not duplicate separate verify/view entries"
  ! printf '%s\n' "$frpc_menu" | grep -Fq '默认 frpc 客户端' || fail "frpc menu should not repeat long default client text"
  ! printf '%s\n' "$frpc_menu" | grep -Fq 'systemd 服务' || fail "frpc menu should use short service text"
  assert_contains '2) 服务管理' <(printf '%s\n' "$frps_menu") "frps menu exposes service management"
  assert_contains '3) 接入码' <(printf '%s\n' "$frps_menu") "frps menu has short pairing entry"
  assert_contains '4) 配置' <(printf '%s\n' "$frps_menu") "frps menu groups view edit verify config"
  ! printf '%s\n' "$frps_menu" | grep -Fq '6)' || fail "frps menu should not duplicate separate verify/view entries"
  ! declare -F config_management_menu >/dev/null || fail "top-level duplicate config menu should be removed"
  ! declare -F show_logs_menu >/dev/null || fail "top-level duplicate logs menu should be removed"
  ! declare -f curl_download | grep -Fq 'curl -fL ' || fail "curl download should be silent and not show progress meter"
  ! grep -Fq 'systemctl --no-pager --full status' "${ROOT_DIR}/frp.sh" || fail "script should not dump full systemd status in normal flow"
  declare -f create_xtcp_exposed_and_code | grep -Fq 'restart_service_if_present "$SELECTED_FRPC_SERVICE"' || fail "xtcp exposed setup should restart/register exposed proxy"
  declare -f configure_frps | grep -Fq '是否启用 frps Dashboard / Prometheus" "n"' || fail "frps dashboard should not be enabled by default"
  declare -f configure_frps | grep -Fq '127.0.0.1' || fail "frps dashboard should default to local address"
  declare -f configure_frps | grep -Fq '不能和 kcpBindPort' || fail "frps should prevent kcp/quic UDP port conflicts"

  local import_cmd
  import_cmd="$(render_one_click_import_command "xtcp" "IFRP-XTCP-V1:abc" "pa ss'word")"
  assert_contains '--import-xtcp-code' <(printf '%s\n' "$import_cmd") "xtcp one-click command uses cli import"
  assert_contains "'pa ss'\\''word'" <(printf '%s\n' "$import_cmd") "one-click command quotes passphrase"
  ! printf '%s\n' "$import_cmd" | grep -Fq '/refs/heads/main/' || fail "one-click command should avoid stale refs/heads raw cache"
  declare -f export_frps_pairing_code | grep -Fq 'render_one_click_import_command "frps"' || fail "frps export should print one-click import command"
  declare -f create_xtcp_exposed_and_code | grep -Fq 'render_one_click_import_command "xtcp"' || fail "xtcp export should print one-click import command"
  declare -f run_cli | grep -Fq 'import_frps_pairing_code "${2:-}" "${3:-}" "true" "${4:-}"' || fail "cli frps import should use strict verify and explicit target"
  declare -f run_cli | grep -Fq 'import_xtcp_code_to_visitor "${2:-}" "${3:-}" "true" "${4:-}"' || fail "cli xtcp import should use strict verify and explicit target"

  local restart_output
  if ! restart_output="$( ( has_cmd() { return 1; }; restart_service_if_present frpc ) 2>&1 )"; then
    fail "restart_service_if_present should not fail under set -u when prompt is omitted: ${restart_output}"
  fi
  assert_contains '无法重启 frpc' <(printf '%s\n' "$restart_output") "restart helper handles omitted prompt"

  local service_output
  if ! service_output="$( (
    has_cmd() { [[ "$1" == "systemctl" ]]; }
    service_exists() { return 0; }
    systemctl() { return 0; }
    print_service_summary() { printf 'unexpected summary\n'; }
    service_action frpc restart false
  ) 2>&1 )"; then
    fail "service action should not fail when summary is suppressed: ${service_output}"
  fi
  [[ -z "$service_output" ]] || fail "service action should not print summary when suppressed: ${service_output}"
  pass "service action handles suppressed summary"
}

main() {
  bash -n "${ROOT_DIR}/frp.sh"
  pass "frp.sh syntax"
  test_instance_helpers_exist
  test_instance_paths
  test_frpc_base_config_renderer
  test_named_instance_lifecycle_helpers
  test_config_edit_helpers
  test_verify_config_behavior
  test_global_verify_and_logs_cover_instances
  test_log_fix_all_is_best_effort
  test_frpc_proxy_target_helpers
  test_import_targets_and_safe_failures
  test_xtcp_import_code_helpers
  test_frps_pairing_code_helpers
  test_install_state_and_status_bar
  printf 'All %d tests passed.\n' "$pass_count"
}

main "$@"
