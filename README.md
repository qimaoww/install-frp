# install-frp

适合想快速部署 frp，同时又希望保留完整可控配置的人使用。

> frp 官方文档：https://gofrp.org/zh-cn/docs/  
> frp 项目地址：https://github.com/fatedier/frp

---

## 功能特性

- 一键安装 / 更新 `frps` 服务端和 `frpc` 客户端
- `frps` 与 `frpc` 分开管理，菜单更清晰
- 支持多个独立 `frpc` 客户端实例
- 自动获取 frp 最新版本，也可手动指定版本
- 默认生成 TOML 配置，并使用 `frps/frpc verify -c` 校验
- `frpc` 默认使用 `auth.tokenSource.file.path`，避免 token 明文写入主配置
- 支持 `frps/frpc` 启动、停止、重启、自启管理、文件日志、脚本日志
- 支持编辑 `frps.toml`、`frpc.toml`、`frpc.d/*.toml` 和命名实例配置
- 编辑配置前自动备份，编辑后可校验并重启服务
- 支持 `frps` 导出加密接入码，新机器一键导入为 `frpc`
- 支持 XTCP/STCP 加密导入码，减少两端手工配对出错
- 支持自定义 frpc 预设、手动代理/访问者、直接粘贴 TOML
- 支持安装摘要查看和完整卸载

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

菜单顶部只显示运行概况；版本和配置细节在子菜单和安装摘要里查看：

```text
frp 管理脚本 2026.05.27-r8
状态：服务端:未运行 | 客户端:运行中 | 实例:2
```

```text
1) 服务端
2) 客户端
3) 配置
4) 日志
5) 工具
0) 退出
```

更新二进制、校验全部配置、安装摘要、GitHub 下载代理和卸载都放在“工具/维护”里。

---

## frps 服务端管理

```text
1) 安装/更新
2) 启动/停止/重启
3) 接入码
4) 校验
5) 查看
6) 日志
0) 返回
```

安装服务端会生成：

```bash
/etc/frp/frps.toml
/etc/systemd/system/frps.service
```

安装/更新时会先读取本机已安装版本。如果目标版本和本机版本一致，默认跳过二进制下载；需要强制覆盖时按提示选择重新下载。

### 导出 frpc 加密接入码

在服务端选择“接入码”，脚本会读取 `frps` 的端口和 token，询问公网地址、协议、TLS 等选项，然后输出加密码、解密码，以及包含二者的一键导入命令：

```text
IFRP-FRPC-V1:<加密内容>
bash <(curl -fsSL 'https://raw.githubusercontent.com/qimaoww/install-frp/refs/heads/main/frp.sh') --import-frps-code 'IFRP-FRPC-V1:...' '解密码'
```

把一键导入命令发到新机器执行，即可解密并生成默认 `frpc` 或命名实例配置。

---

## frpc 客户端管理

```text
1) 安装/更新
2) 启动/停止/重启
3) 实例
4) 接入码
5) 代理配置
6) XTCP
7) 校验
8) 查看
9) 日志
0) 返回
```

默认客户端会生成：

```bash
/etc/frp/frpc.toml
/etc/frp/frpc.d/
/etc/systemd/system/frpc.service
```

`frpc.toml` 会包含：

```toml
auth.method = "token"
auth.tokenSource.type = "file"
auth.tokenSource.file.path = "/etc/frp/token"
includes = ["/etc/frp/frpc.d/*.toml"]
```

---

## 多 frpc 实例

命名实例适合一台机器同时连接多个不同的 `frps`，或用不同 token、协议、代理目录隔离配置。

每个实例独立保存：

```text
/etc/frp/clients/<name>/frpc.toml
/etc/frp/clients/<name>/frpc.d/*.toml
/etc/frp/clients/<name>/token
/var/log/frp/frpc-<name>.log
```

systemd 使用模板服务：

```bash
systemctl status frpc@home
systemctl restart frpc@home
systemctl enable frpc@home
journalctl -u frpc@home -n 100 --no-pager
```

也可以直接走脚本入口管理服务：

```bash
bash frp.sh --service frps restart
bash frp.sh --service frpc restart
bash frp.sh --service frpc@home restart
```

---

## 配置管理

```text
1) 编辑 frps 主配置
2) 编辑默认 frpc 主配置
3) 编辑默认 frpc.d 代理配置
4) 编辑命名 frpc 实例主配置
5) 编辑命名 frpc 实例代理配置
0) 返回
```

编辑器选择顺序：

```text
$EDITOR -> nano -> vim -> vi -> 粘贴覆盖模式
```

每次编辑前会生成 `.bak.YYYYMMDD-HHMMSS` 备份。编辑后会执行：

```bash
frps verify -c /etc/frp/frps.toml
frpc verify -c /etc/frp/frpc.toml
```

命名实例会校验对应的 `/etc/frp/clients/<name>/frpc.toml`。

---

## XTCP / STCP 加密导入码

XTCP 需要两端 `frpc` 配对：被访问端创建 `[[proxies]]`，访问端创建 `[[visitors]]`。脚本提供加密导入码，减少手工复制 `serverName`、`secretKey`、fallback 等字段出错。

菜单：

```text
1) 创建被访问端 XTCP 配置并生成加密导入码
2) 粘贴加密导入码生成访问端配置
3) 修复现有 XTCP 配置
0) 返回
```

导入码格式：

```text
IFRP-XTCP-V1:<加密内容>
bash <(curl -fsSL 'https://raw.githubusercontent.com/qimaoww/install-frp/refs/heads/main/frp.sh') --import-xtcp-code 'IFRP-XTCP-V1:...' '解密码'
```

创建被访问端 XTCP 配置后，脚本会提示重启对应 `frpc`，让 `[[proxies]]` 注册到 `frps`。如果跳过这一步，访问端会看到类似 `xtcp server for [name] doesn't exist` 的错误。

脚本会把访问端 XTCP 底层协议写入导入码。默认使用 `kcp`；如果你想沿用 frp 默认行为，也可以选择 `quic`。当日志里出现 Docker、VPN、`100.64.0.0/10` 之类辅助地址干扰时，建议启用“禁用辅助地址”。新生成配置会在被访问端 proxy 和访问端 visitor 两边写入：

```toml
protocol = "kcp"

[proxies.natTraversal]
disableAssistedAddrs = true

[visitors.natTraversal]
disableAssistedAddrs = true
```

旧配置可以直接在 XTCP 菜单选择“修复现有 XTCP 配置”，脚本会备份后把现有 `quic` visitor 改成 `kcp`，把 `fallbackTimeoutMs` 调到 5000，并补齐 `disableAssistedAddrs`。

如果启用 STCP fallback，脚本会在被访问端生成 `xtcp + stcp` 两个 proxy，在访问端生成 `stcp visitor + xtcp visitor`，并自动写入：

```toml
fallbackTo = "<stcp-visitor-name>"
fallbackTimeoutMs = 5000
```

`fallbackTimeoutMs` 默认 5000ms。打洞通常需要 1 到 5 秒，设置太短会出现“打洞其实快成功了，但用户连接已经 fallback 或超时”的现象。

---

## 自定义 frpc 预设

预设目录：

```bash
/etc/frp/presets.d/
```

代理拆分配置目录：

```bash
/etc/frp/frpc.d/
```

预设是 TOML 模板文件，支持 `${name}` 或 `{{name}}` 占位符：

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

---

## 日志

默认文件日志：

```bash
/var/log/frp/frps.log
/var/log/frp/frpc.log
/var/log/frp/frpc-<name>.log
/var/log/frp/installer.log
```

常用命令：

```bash
tail -n 200 /var/log/frp/frps.log
tail -f /var/log/frp/frpc.log
journalctl -u frps -n 100 --no-pager
journalctl -u frpc@home -n 100 --no-pager
```

---

## 文件结构

```text
/usr/local/bin/frps                    frps 二进制
/usr/local/bin/frpc                    frpc 二进制

/etc/frp/frps.toml                     frps 主配置
/etc/frp/frpc.toml                     默认 frpc 主配置
/etc/frp/frpc.d/                       默认 frpc 拆分代理配置
/etc/frp/clients/<name>/               命名 frpc 实例目录
/etc/frp/presets.d/                    frpc 自定义预设目录
/etc/frp/token                         默认 tokenSource 文件
/etc/frp/installer.env                 脚本配置

/etc/systemd/system/frps.service       frps systemd 服务
/etc/systemd/system/frpc.service       默认 frpc systemd 服务
/etc/systemd/system/frpc@.service      命名 frpc 实例模板服务
```

---

## 环境变量

临时指定 frp 版本：

```bash
VERSION=v0.68.1 bash frp.sh
```

只加载函数，不进入菜单，适合开发测试：

```bash
FRP_LIB_ONLY=1 source ./frp.sh
```

配置 GitHub 下载代理：

```bash
GH_PROXY=https://ghfast.top/ bash frp.sh
```

---

## 安全提醒

- 不要公开 `auth.token`、`tokenSource` 文件内容或加密接入码解密码
- 不要公开 XTCP/STCP 的 `secretKey`、XTCP 导入码解密码
- Dashboard / Admin UI 建议只监听 `127.0.0.1`
- 如果必须公网暴露 Dashboard / Admin UI，请务必使用强密码，并通过防火墙限制来源 IP
- `frpc.d`、命名实例目录和 `presets.d` 中可能包含敏感信息，请谨慎备份和分享
- 日志中可能包含域名、IP、代理名等信息，请谨慎公开

---

## 开发验证

```bash
bash tests/run.sh
bash -n frp.sh
```

---

## 免责声明

本脚本会修改系统服务、写入配置文件并安装二进制文件。请在执行前确认你理解相关操作。建议在生产环境使用前先在测试机验证配置。
