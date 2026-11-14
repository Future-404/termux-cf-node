# 验证记录

验证日期：2026-11-14。运行环境为 Linux 测试主机；没有使用用户的 Cloudflare 凭据，没有创建或更改 Cloudflare Tunnel。

## 已通过

- Bash 语法检查。
- ShellCheck 0.11.0（包括生成服务所需的 shell 代码）。
- sing-box 1.14.4 校验服务端、本地 WS 客户端与公网 WSS 客户端配置。
- 真实 sing-box 客户端 → SOCKS → VLESS/WS 服务端 → 私有 HTTP 测试目标的数据转发。
- 错误 UUID、错误 WS Path 被拒绝。
- 真实 runit 2.2.0 服务启动、停止和进程退出后的自动重启。
- 停止后保持停止状态。
- 同一个安装目录连续切换三代配置，只保留当前和上一代。
- 实际回退到上一代配置并重新启动服务。
- 带空格的 HOME 目录、分享链接的中文/空格/路径编码、Token 文件权限。
- 生成的管理入口和 Termux:Boot 文件语法。
- 真实 cloudflared 2026.7.3 接受生成的命令参数，包括 `--token-file`、显式 DNS、传输协议和本机 metrics 地址。使用无效测试 Token 验证参数解析，Token 在建立连接前被拒绝。
- 1.1.0 自动部署：真实交互式安装流程和真实 curl，连接本机私有 HTTPS Cloudflare API 模拟器。验证 API Token 仅通过 Header 文件传递、完成或失败后清理、自动识别最具体 Zone、首次创建 / 多次复用、旧版迁移、保留其他 Tunnel 路由、远程配置回退、API 权限错误、非 JSON 响应、无关 DNS 记录冲突、DNS 写入失败后的回源恢复，以及创建请求响应丢失后的无重复重试。

主机服务测试中，`sing-box`、`runit` 和 HTTP 目标为真实进程；Termux 的平台启动器使用测试适配器，cloudflared 连接器使用仅记录参数的测试进程。测试不会把连接器进程存在当作 Cloudflare 连通成功。

## 仍需手机验收

- Android / Termux 实机软件包安装。
- 用户域名、边缘证书、真实 Token 和远程管理的 Tunnel 路由。
- Cloudflare 真实账户上的 API 创建 / 配置 / DNS 写入。API 测试使用符合官方请求和响应结构的 HTTPS 模拟器，不能替代真实账户验收。
- 手机网络到配置的 DNS、Cloudflare Tunnel 和目标网站的可达性。
- Android 厂商的后台保活、重启与 Termux:Boot 行为。
- 从另一个网络连接节点并核对手机出口 IP。

部署后先运行 `tcf-node diagnose`，再用外部设备实际导入节点验证。

## 复现主机集成测试

安装或准备 Bash、jq、curl、Python 3、coreutils、util-linux、sing-box 和 runit。在项目目录中执行：

API HTTPS 模拟测试另需 `openssl`，用于生成临时测试证书；不需要 Python 第三方依赖。

```bash
bash -n termux-cf-node.sh
bash -n tests/smoke.sh
shellcheck -x termux-cf-node.sh tests/smoke.sh
SB_BIN=/absolute/path/to/sing-box \
RUNIT_BIN=/absolute/path/to/runit/bin \
bash tests/smoke.sh
SB_BIN=/absolute/path/to/sing-box python3 tests/api-smoke.py
```

测试只在临时目录建立服务和配置，退出时停止所属测试进程并清理。生产脚本仍限制在普通 Termux 用户中运行；测试通过加载函数验证跨平台逻辑，不增加绕过检查的生产开关。
