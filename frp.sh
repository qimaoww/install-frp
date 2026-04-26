#!/bin/bash

# 检查是否为 root 用户
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 用户或 sudo 运行此脚本！"
  exit 1
fi

# 控制台颜色
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RED="\033[31m"
RESET="\033[0m"

echo -e "${CYAN}==================================================${RESET}"
echo -e "${GREEN}       frp 终极自定义安装脚本 (支持 TOML v0.52+)${RESET}"
echo -e "${CYAN}==================================================${RESET}"

# 获取最新版本
echo "正在获取 frp 最新版本..."
VERSION=$(curl -s https://api.github.com/repos/fatedier/frp/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
if [ -z "$VERSION" ]; then
  echo -e "${RED}获取最新版本失败，请检查网络。${RESET}"
  exit 1
fi
echo -e "发现最新版本: ${GREEN}v${VERSION}${RESET}"

# 获取系统架构
ARCH=$(uname -m)
case $ARCH in
  x86_64)  FRP_ARCH="amd64" ;;
  aarch64) FRP_ARCH="arm64" ;;
  armv7l)  FRP_ARCH="arm" ;;
  *)       echo -e "${RED}不支持的系统架构: $ARCH${RESET}"; exit 1 ;;
esac

FILE_NAME="frp_${VERSION}_linux_${FRP_ARCH}"
TAR_FILE="${FILE_NAME}.tar.gz"
DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/v${VERSION}/${TAR_FILE}"

# 下载并解压
download_and_extract() {
  echo "正在下载 frp v${VERSION} (${FRP_ARCH})..."
  wget -O ${TAR_FILE} ${DOWNLOAD_URL}
  if [ $? -ne 0 ]; then
    echo -e "${RED}下载失败！请检查网络。${RESET}"
    exit 1
  fi
  tar -zxvf ${TAR_FILE} > /dev/null
  cd ${FILE_NAME} || exit 1
}

# ================= 服务端 (frps) 自定义配置 =================
install_frps() {
  download_and_extract
  cp frps /usr/local/bin/
  chmod +x /usr/local/bin/frps
  mkdir -p /etc/frp

  echo -e "\n${CYAN}>>> 开始自定义配置 服务端 (frps) <<<${RESET}"
  
  read -p "1. 请输入 frps 绑定端口 [默认 7000]: " bind_port
  bind_port=${bind_port:-7000}

  # 只有服务端需要生成随机 Token 供参考
  RANDOM_TOKEN=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)
  echo -e "2. 请配置鉴权 Token (防止服务端被滥用)"
  read -p "[直接回车随机生成: ${YELLOW}${RANDOM_TOKEN}${RESET} | 自定义请直接输入 | 输入 none 禁用]: " input_token
  
  if [ -z "$input_token" ]; then
    auth_token=$RANDOM_TOKEN
  elif [ "$input_token" == "none" ]; then
    auth_token=""
  else
    auth_token=$input_token
  fi

  read -p "3. 是否需要开启 HTTP Web 穿透端口(vhost_http_port)? [y/N]: " enable_vhost
  if [[ "$enable_vhost" =~ ^[Yy]$ ]]; then
    read -p "   请输入 HTTP 穿透端口 [默认 80]: " vhost_http
    vhost_http=${vhost_http:-80}
    read -p "   请输入 HTTPS 穿透端口 (不需要则留空): " vhost_https
  fi

  read -p "4. 是否开启 Web 管理面板?[y/N]: " enable_dash

  # 开始生成 frps.toml
  cat > /etc/frp/frps.toml <<EOF
bindPort = ${bind_port}
EOF

  if[ -n "$auth_token" ]; then
    cat >> /etc/frp/frps.toml <<EOF
auth.method = "token"
auth.token = "${auth_token}"
EOF
  fi

  if [[ "$enable_vhost" =~ ^[Yy]$ ]]; then
    cat >> /etc/frp/frps.toml <<EOF
vhostHTTPPort = ${vhost_http}
EOF
    if [ -n "$vhost_https" ]; then
      cat >> /etc/frp/frps.toml <<EOF
vhostHTTPSPort = ${vhost_https}
EOF
    fi
  fi

  if [[ "$enable_dash" =~ ^[Yy]$ ]]; then
    read -p "   请输入 Web 面板端口 [默认 7500]: " dash_port
    dash_port=${dash_port:-7500}
    read -p "   请输入 Web 面板账号[默认 admin]: " dash_user
    dash_user=${dash_user:-admin}
    read -p "   请输入 Web 面板密码 [默认 admin]: " dash_pwd
    dash_pwd=${dash_pwd:-admin}

    cat >> /etc/frp/frps.toml <<EOF

webServer.addr = "0.0.0.0"
webServer.port = ${dash_port}
webServer.user = "${dash_user}"
webServer.password = "${dash_pwd}"
EOF
  fi

  create_systemd "frps"
  echo -e "\n${GREEN}✅ frps 安装并启动成功！${RESET}"
  echo -e "配置文件已保存至: /etc/frp/frps.toml"
  
  echo -e "\n${CYAN}================[ 服务端信息摘要 ] =================${RESET}"
  echo -e "服务端 IP : (你的公网IP)"
  echo -e "绑定端口  : ${YELLOW}${bind_port}${RESET}"
  if[ -n "$auth_token" ]; then
    echo -e "鉴权 Token: ${YELLOW}${auth_token}${RESET}  <-- 【重要】请在配置客户端时填入此密钥！"
  else
    echo -e "鉴权 Token: ${RED}未开启 (极不推荐，存在被滥用风险)${RESET}"
  fi
  if [[ "$enable_dash" =~ ^[Yy]$ ]]; then
    echo -e "Web 面板  : http://<公网IP>:${dash_port} (账号:${dash_user} 密码:${dash_pwd})"
  fi
  echo -e "${CYAN}=====================================================${RESET}"
  
  cleanup
}

# ================= 客户端 (frpc) 自定义配置 =================
install_frpc() {
  download_and_extract
  cp frpc /usr/local/bin/
  chmod +x /usr/local/bin/frpc
  mkdir -p /etc/frp

  echo -e "\n${CYAN}>>> 开始自定义配置 客户端 (frpc) 基础信息 <<<${RESET}"
  read -p "1. 请输入服务端(公网) IP 或域名: " server_addr
  if [ -z "$server_addr" ]; then
    echo -e "${RED}服务端地址不能为空！${RESET}"; exit 1
  fi
  
  read -p "2. 请输入服务端绑定端口 [默认 7000]: " server_port
  server_port=${server_port:-7000}

  # 客户端 Token 配置（仅接受手动输入）
  echo -e "3. 请输入鉴权 Token ${YELLOW}(必须与你服务端的 token 完全一致)${RESET}"
  read -p "[请直接输入或粘贴，若服务端未开启则留空直接回车]: " auth_token

  # 生成基础配置
  cat > /etc/frp/frpc.toml <<EOF
serverAddr = "${server_addr}"
serverPort = ${server_port}
EOF

  if[ -n "$auth_token" ]; then
    cat >> /etc/frp/frpc.toml <<EOF
auth.method = "token"
auth.token = "${auth_token}"
EOF
  fi

  echo -e "\n${CYAN}>>> 开始配置穿透规则 (代理) <<<${RESET}"
  while true; do
    read -p "是否添加一条新的穿透规则?[Y/n] (默认 Y): " add_proxy
    add_proxy=${add_proxy:-Y}
    if [[ ! "$add_proxy" =~ ^[Yy]$ ]]; then
      break
    fi

    echo -e "${YELLOW}请选择协议类型:${RESET} 1) tcp  2) udp  3) http  4) https"
    read -p "输入数字选择[默认 1]: " p_type_num
    case ${p_type_num:-1} in
      1) p_type="tcp" ;;
      2) p_type="udp" ;;
      3) p_type="http" ;;
      4) p_type="https" ;;
      *) p_type="tcp" ;;
    esac

    read -p "请输入规则名称 (必须唯一，如 ssh_test): " proxy_name
    if [ -z "$proxy_name" ]; then echo -e "${RED}名称不能为空，重新配置！${RESET}"; continue; fi

    read -p "请输入本地 IP[默认 127.0.0.1]: " local_ip
    local_ip=${local_ip:-127.0.0.1}

    read -p "请输入本地端口[如 22, 80]: " local_port
    if [ -z "$local_port" ]; then echo -e "${RED}本地端口不能为空，重新配置！${RESET}"; continue; fi

    # 写入公共部分
    cat >> /etc/frp/frpc.toml <<EOF

[[proxies]]
name = "${proxy_name}"
type = "${p_type}"
localIP = "${local_ip}"
localPort = ${local_port}
EOF

    # 根据协议类型要求不同的参数
    if [ "$p_type" == "tcp" ] ||[ "$p_type" == "udp" ]; then
      read -p "请输入远端映射端口 (访问公网服务器的该端口)[如 6000]: " remote_port
      cat >> /etc/frp/frpc.toml <<EOF
remotePort = ${remote_port}
EOF
    elif[ "$p_type" == "http" ] || [ "$p_type" == "https" ]; then
      echo -e "${YELLOW}提示: HTTP/HTTPS 协议需服务端配置了 vhost_http(s)_port${RESET}"
      read -p "请输入绑定的自定义域名 (如 www.test.com): " custom_domain
      cat >> /etc/frp/frpc.toml <<EOF
customDomains =["${custom_domain}"]
EOF
    fi
    echo -e "${GREEN}✅ 规则[${proxy_name}] 添加成功！${RESET}\n"
  done

  create_systemd "frpc"
  echo -e "\n${GREEN}✅ frpc 安装并启动成功！${RESET}"
  echo "配置文件已保存至: /etc/frp/frpc.toml"
  cleanup
}

# ================= 创建 systemd 服务 =================
create_systemd() {
  local service_name=$1
  echo "正在配置 systemd 守护进程 (${service_name})..."
  
  local reload_cmd=""
  if [ "$service_name" == "frpc" ]; then
    reload_cmd="ExecReload=/usr/local/bin/frpc reload -c /etc/frp/frpc.toml"
  fi

  cat > /etc/systemd/system/${service_name}.service <<EOF[Unit]
Description=Frp ${service_name} Service
After=network.target

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
ExecStart=/usr/local/bin/${service_name} -c /etc/frp/${service_name}.toml
${reload_cmd}
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable ${service_name}
  systemctl start ${service_name}
}

# ================= 卸载功能 =================
uninstall_frp() {
  systemctl stop frps 2>/dev/null
  systemctl disable frps 2>/dev/null
  systemctl stop frpc 2>/dev/null
  systemctl disable frpc 2>/dev/null
  
  rm -f /usr/local/bin/frps /usr/local/bin/frpc
  rm -f /etc/systemd/system/frps.service /etc/systemd/system/frpc.service
  systemctl daemon-reload

  echo -e "${GREEN}二进制文件及服务已清理。${RESET}"
  read -p "是否删除配置文件目录 /etc/frp ?[y/N]: " del_conf
  if [[ "$del_conf" =~ ^[Yy]$ ]]; then
    rm -rf /etc/frp
    echo "配置目录已删除。"
  fi
  echo -e "${GREEN}✅ 卸载完成。${RESET}"
}

cleanup() {
  cd .. && rm -rf ${FILE_NAME} ${TAR_FILE}
}

# ================= 主菜单 =================
echo -e "1) 安装 ${GREEN}服务端 frps${RESET} (公网服务器)"
echo -e "2) 安装 ${CYAN}客户端 frpc${RESET} (内网机器)"
echo -e "3) 卸载 frp"
echo -e "0) 退出"
echo -e "${CYAN}==================================================${RESET}"
read -p "请输入数字选择操作: " choice

case $choice in
  1) install_frps ;;
  2) install_frpc ;;
  3) uninstall_frp ;;
  0) exit 0 ;;
  *) echo -e "${RED}输入无效，退出。${RESET}" ; exit 1 ;;
esac
