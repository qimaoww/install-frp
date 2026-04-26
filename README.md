# install-frp


适合想快速部署 frp，同时又希望保留完整可控配置的人使用。

> frp 官方文档：https://gofrp.org/zh-cn/docs/  
> frp 项目地址：https://github.com/fatedier/frp

---

## 功能特性

- 一键安装 / 更新 `frps` 服务端
- 一键安装 / 更新 `frpc` 客户端
- 自动获取 frp 最新版本
- 支持手动指定 frp 版本
- 支持 systemd 服务管理
- 支持 TOML 配置文件
- 支持配置校验
- 支持查看当前配置
- 支持查看 systemd 日志、文件日志、脚本日志
- 支持一键修复 / 启用文件日志
- 支持自定义 frpc 预设
- 支持手动添加 frpc 代理 / 访问者
- 支持直接粘贴任意 TOML 到 `frpc.d`
- 支持安装摘要查看
- 支持完整卸载

---

## 快速开始

### 直接运行

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/qimaoww/install-frp/refs/heads/main/frp.sh")
```


### 手动下载运行

```bash
curl -fsSL -o frp.sh "https://raw.githubusercontent.com/qimaoww/install-frp/refs/heads/main/frp.sh"
chmod +x frp.sh
sudo bash frp.sh
```

---

## 主菜单

```text
1) 安装/更新 frps 服务端
2) 安装/更新 frpc 客户端
3) 仅安装/更新 frp 二进制文件
4) 添加/套用 frpc 配置（自定义预设）
5) 管理 systemd 服务
6) 校验配置
7) 查看当前配置
8) 查看日志
9) 查看安装摘要
10) 卸载 frp
0) 退出
```

---

## 安装 frps 服务端

选择：

```text
1) 安装/更新 frps 服务端
```

脚本会交互询问：

- frp 版本
- `bindAddr`
- `bindPort`
- 鉴权 `token`
- 是否启用 KCP
- 是否启用 QUIC
- 是否启用 HTTP 虚拟主机端口
- 是否启用 HTTPS 虚拟主机端口
- 是否配置 `subDomainHost`
- 是否启用 Dashboard / Prometheus
- 最大连接池数量
- 是否放行防火墙端口
- 是否启动并启用 systemd 服务

生成配置：

```bash
/etc/frp/frps.toml
```

生成服务：

```bash
/etc/systemd/system/frps.service
```

常用命令：

```bash
systemctl status frps
systemctl restart frps
journalctl -u frps -n 100 --no-pager
```

---

## 安装 frpc 客户端

选择：

```text
2) 安装/更新 frpc 客户端
```

脚本会交互询问：

- frp 版本
- frps 服务器地址
- frps 服务器端口
- 鉴权 `token`
- 客户端 `user`
- 通信协议：`tcp` / `kcp` / `quic` / `websocket` / `wss`
- 是否启用 TLS
- 连接池数量
- 自定义 DNS
- 是否启用 Admin UI
- 是否启用 Store 动态代理持久化

生成主配置：

```bash
/etc/frp/frpc.toml
```

生成拆分代理目录：

```bash
/etc/frp/frpc.d/
```

生成服务：

```bash
/etc/systemd/system/frpc.service
```

常用命令：

```bash
systemctl status frpc
systemctl restart frpc
journalctl -u frpc -n 100 --no-pager
```

---


## 自定义 frpc 预设

脚本不会把“预设”写死成固定模板，而是提供一个 **自定义预设管理器**。

预设目录：

```bash
/etc/frp/presets.d/
```

代理拆分配置目录：

```bash
/etc/frp/frpc.d/
```

进入菜单：

```text
4) 添加/套用 frpc 配置（自定义预设）
```

子菜单：

```text
1) 套用自定义预设
2) 管理自定义预设
3) 高级手动添加代理/访问者
4) 直接粘贴 TOML 到 frpc.d
0) 返回
```

预设管理菜单：

```text
1) 套用自定义预设生成 frpc.d 配置
2) 创建自定义预设
3) 编辑自定义预设
4) 查看自定义预设
5) 删除自定义预设
6) 导入可编辑示例预设
7) 直接粘贴 TOML 到 frpc.d
0) 返回
```

### 预设格式

预设是一个 TOML 模板文件，支持变量占位符：

- `${name}`
- `{{name}}`

示例：

```toml
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
```

保存为：

```bash
/etc/frp/presets.d/tcp-custom.tpl
```

套用后会交互询问变量值，并生成：

```bash
/etc/frp/frpc.d/tcp-custom.toml
```

然后重启 `frpc` 生效：

```bash
systemctl restart frpc
```

---

## 手动添加代理 / 访问者

选择：

```text
4) 添加/套用 frpc 配置（自定义预设）
3) 高级手动添加代理/访问者
```

支持类型：

```text
tcp
udp
http
https
stcp
xtcp
sudp
stcp-visitor
xtcp-visitor
sudp-visitor
```

脚本会根据类型交互生成对应 TOML，并写入：

```bash
/etc/frp/frpc.d/<name>.toml
```

---

## 直接粘贴 TOML

如果你想完全按官方文档自己写配置，可以选择：

```text
4) 添加/套用 frpc 配置（自定义预设）
4) 直接粘贴 TOML 到 frpc.d
```

粘贴内容后，单独输入：

```text
EOF
```

结束输入。

---

## 配置校验

选择：

```text
6) 校验配置
```

脚本会自动执行：

```bash
frps verify -c /etc/frp/frps.toml
frpc verify -c /etc/frp/frpc.toml
```

如果只安装了 `frps` 或只安装了 `frpc`，脚本会自动跳过不存在的另一端，不会报错退出。

---

## 查看当前配置

选择：

```text
7) 查看当前配置
```

支持查看：

```text
1) 查看 frps.toml
2) 查看 frpc.toml
3) 查看 frpc.d 拆分代理配置
4) 查看 token / installer.env
5) 查看全部配置
```


---

## 查看日志

选择：

```text
8) 查看日志
```

日志菜单：

```text
1) frps 综合日志（推荐）
2) frpc 综合日志（推荐）
3) frps systemd 日志
4) frpc systemd 日志
5) frps 文件日志 /var/log/frp/frps.log
6) frpc 文件日志 /var/log/frp/frpc.log
7) 脚本安装/管理日志 /var/log/frp/installer.log
8) 全部最近日志
9) 一键修复/启用文件日志
0) 返回
```

默认文件日志：

```bash
/var/log/frp/frps.log
/var/log/frp/frpc.log
/var/log/frp/installer.log
```

如果 systemd 日志里只看到类似：

```text
Started frps.service - frp s service.
```

这是正常的。脚本默认把 frp 业务日志写入文件日志，而不是 systemd stdout。

可以直接查看：

```bash
tail -n 200 /var/log/frp/frps.log
tail -f /var/log/frp/frps.log
```

---

## systemd 服务管理

选择：

```text
5) 管理 systemd 服务
```

支持操作：

```text
status
start
stop
restart
logs -f
enable
disable
```

手动命令：

```bash
systemctl status frps
systemctl restart frps
systemctl enable frps

systemctl status frpc
systemctl restart frpc
systemctl enable frpc
```

---

## 安装摘要

选择：

```text
9) 查看安装摘要
```

会显示：

- 安装目录
- frps / frpc 版本
- 配置目录
- frpc 拆分配置目录
- 自定义预设目录
- 日志目录
- systemd 服务状态

---

## 卸载

选择：

```text
10) 卸载 frp
```

脚本会：

- 停止 `frps` / `frpc`
- 禁用 systemd 服务
- 删除 systemd service 文件
- 删除 `/usr/local/bin/frps`
- 删除 `/usr/local/bin/frpc`
- 可选删除 `/etc/frp`
- 可选删除 `/var/log/frp`

---

## 文件结构

```text
/usr/local/bin/frps              frps 二进制
/usr/local/bin/frpc              frpc 二进制

/etc/frp/frps.toml               frps 主配置
/etc/frp/frpc.toml               frpc 主配置
/etc/frp/frpc.d/                 frpc 拆分代理配置目录
/etc/frp/presets.d/              frpc 自定义预设目录
/etc/frp/token                   鉴权 token
/etc/frp/installer.env           脚本配置

/var/log/frp/frps.log            frps 文件日志
/var/log/frp/frpc.log            frpc 文件日志
/var/log/frp/installer.log       脚本安装/管理日志

/etc/systemd/system/frps.service frps systemd 服务
/etc/systemd/system/frpc.service frpc systemd 服务
```

---

## 环境变量


### `VERSION`

临时指定 frp 版本：

```bash
VERSION=v0.68.1 bash frp.sh
```

### `FRP_LIB_ONLY`

只加载函数，不进入菜单，适合开发调试：

```bash
FRP_LIB_ONLY=1 source ./frp.sh
```

---


---

## 安全提醒

- 不要公开 `auth.token`
- 不要公开 `secretKey`
- 不要公开 Dashboard / Admin UI 密码
- Dashboard / Admin UI 建议只监听 `127.0.0.1`
- 如果必须公网暴露 Dashboard / Admin UI，请务必使用强密码，并通过防火墙限制来源 IP
- `frpc.d` 和 `presets.d` 中可能包含敏感信息，请谨慎备份和分享
- 日志中可能包含域名、IP、代理名等信息，请谨慎公开

---

## 更新脚本

重新拉取并运行：

```bash
curl -fsSL -o frp.sh "https://raw.githubusercontent.com/qimaoww/install-frp/refs/heads/main/frp.sh"
chmod +x frp.sh
sudo bash frp.sh
```

然后选择：

```text
1) 安装/更新 frps 服务端
2) 安装/更新 frpc 客户端
3) 仅安装/更新 frp 二进制文件
```

---



---

## 免责声明

本脚本会修改系统服务、写入配置文件并安装二进制文件。请在执行前确认你理解相关操作。建议在生产环境使用前先在测试机验证配置。
