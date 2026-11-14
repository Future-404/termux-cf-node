# Termux Cloudflare VLESS/WS 服务端

在 Android 原生 Termux 中运行 `sing-box + cloudflared`，以固定域名提供 VLESS over WSS 节点，最终从手机网络出站。**输入 Cloudflare API Token 和节点域名，脚本自动创建 / 复用 Tunnel、配置回源与 DNS，不需要在网页端创建 Tunnel。**

```text
客户端 → 域名:443/WSS → Cloudflare → Tunnel → 手机 127.0.0.1:8080/WS → 目标网站
```

手机无需 root、公网入站端口或本地 TLS 证书。公网稳定也可以使用，Tunnel 本身不要求公网 IP。手机网络需要能访问 Cloudflare Tunnel 和目标网站。

使用当前 Termux 软件源中的软件包。配置要求 sing-box 1.12+，cloudflared 2025.7.0+；脚本会检查配置及所需参数。

## 开始使用

在 Termux 粘贴以下一行命令，自动下载脚本并打开交互菜单：

```bash
pkg install -y curl && curl -fL --retry 3 'https://raw.githubusercontent.com/Future-404/termux-cf-node/main/termux-cf-node.sh' -o "$HOME/termux-cf-node.sh" && bash "$HOME/termux-cf-node.sh"
```

下载完成才执行，交互输入仍从终端读取。安装后直接输入 `tcf-node` 管理节点。

也可以手动下载：

1. 安装当前版本的 Termux，建议使用官方 GitHub 或 F-Droid 发行版。
2. 将 `termux-cf-node.sh` 下载到手机的 Download 目录。
3. 在 Termux 运行：

```bash
termux-setup-storage
bash ~/storage/downloads/termux-cf-node.sh
```

允许存储权限后，如果 `~/storage/downloads` 仍未出现，请重新运行 `termux-setup-storage`。也可以把脚本放到 Termux 主目录，使用 `bash ~/termux-cf-node.sh` 启动。

选择 `1) 安装 / 重新配置`。脚本从 Termux 软件源安装依赖，然后依次询问：

- 节点域名，例如 `node.example.com`。
- 本地监听端口，默认 `8080`，仅监听 `127.0.0.1`。
- VLESS UUID、随机 WS 路径，可直接回车。
- 节点名称。
- Tunnel 协议，默认 `auto`；UDP 不通时可改为 `http2`。
- 节点与 Tunnel 解析使用的 UDP DNS 地址，默认 `1.1.1.1`。请填写手机网络可访问的 DNS；纯 IPv6 网络使用可达的 IPv6 DNS。显式 DNS 避免依赖 Termux 中可能获取不到的 Android 系统 DNS 列表。
- Cloudflare **API Token**，确认自动部署后隐藏输入。权限见下文。

脚本先检查本地配置，再确认是否自动配置 Cloudflare 并启动。重复配置时，回车保留节点参数；API Token 不会长期保存，需要重新输入。默认不会更新 UUID 或 WS Path，已有客户端无需重新导入；更改它们后请重新导入链接。

## API Token 权限

准备一个已托管到 Cloudflare、处于 active 状态的域名，以及拥有以下权限的 [Cloudflare API Token](https://dash.cloudflare.com/profile/api-tokens)：

| 类型 | 项目 | 权限 |
| --- | --- | --- |
| Account | Cloudflare Tunnel | Edit / Write |
| Zone | Zone | Read |
| Zone | DNS | Edit / Write |

资源范围应包含目标 Zone 和它所属的 Cloudflare 账户。脚本从域名查找最具体的授权 Zone，并从 Zone 数据取得 Account ID，因此无需输入 Account ID / Zone ID，也不要求列出所有账户的权限。多级后缀（如 `.co.uk`）与授权子 Zone 同样支持。

**API Token 与 Tunnel Token 不同**：API Token 用于创建和配置资源；`eyJ...` 格式的 Tunnel Token 用于运行已有 Tunnel。自动部署时输入 API Token；脚本会自行取得后台连接所需的 Tunnel Token。

自动部署执行：

1. 按节点域名自动识别 Zone 和账户。
2. 创建一个远程管理的 Tunnel；重复运行复用该手机、该域名对应的 Tunnel。
3. 配置域名回源到 `http://127.0.0.1:8080`（或你选择的端口），保留最后的 catch-all 规则。
4. 创建启用 Cloudflare 代理的 CNAME，指向 `<Tunnel ID>.cfargotunnel.com`。
5. 获取 Tunnel Token，保存本地配置并启动服务。

公网入口是 HTTPS/WSS；手机回源是 HTTP/WS，仅监听 `127.0.0.1`。不需要开放手机入站端口或配置本地证书。等待 DNS 和 Cloudflare 边缘证书生效后，用 `tcf-node diagnose` 验收。

脚本会保留 Tunnel 中其他域名的路由和全局配置；遇到目标域名已有按路径匹配的规则会拒绝自动修改。目标域名有无关的 A、AAAA、CNAME 或其他冲突记录时，脚本会停止并提示换一个未占用的子域名，不会自动删除这些记录。DNS 写入失败时，会尝试恢复修改前的 Tunnel 回源配置；创建请求超时或中途失败后，重新运行会按稳定名称复用已创建的 Tunnel。

从 1.0 版升级时，重新运行一行命令并选择安装 / 重新配置，输入原来的域名和 API Token。脚本可从手机已有的 Tunnel Token 识别并复用原来的远程管理 Tunnel，无需重新创建。其他连接器如果也连接同一个 Tunnel，应确保它们能够提供相同服务。

节点域名若套用了要求浏览器登录的 Cloudflare Access 或 JS Challenge，普通节点客户端无法连接，仍需使用适合该用途的访问策略。

## 日常管理

完成安装后，输入 `tcf-node` 打开交互菜单，也可以使用命令：

```bash
tcf-node start       # 启动，并检查本地 WS
tcf-node stop        # 停止；保持停止状态，直到再次 start
tcf-node restart
tcf-node status      # 本机进程状态，不代表公网可用
tcf-node node        # 分享链接、导出路径；有 qrencode 时显示二维码
tcf-node diagnose   # 配置检查、本地认证出站、公网认证全链路
tcf-node logs        # 两个服务各最近 60 行日志
tcf-node token       # 输入 API Token，同步 Tunnel / DNS 并更新运行凭据
tcf-node install     # 重新配置，也可改传输协议 / DNS
tcf-node guide      # 显示 API Token 权限说明及目标映射
tcf-node rollback   # 回退上一份配置；API 模式会重新请求 Token 并同步远端
tcf-node boot-on
tcf-node boot-off
tcf-node uninstall  # 确认后删除本节点的本地文件
```

需要二维码时：

```bash
pkg install qrencode
tcf-node node
```

导出的 `clash-meta.json` 是 `proxies` 配置片段，供 Mihomo/Clash Meta 合并使用，不是完整客户端配置。JSON 也是合法的 YAML。默认客户端片段关闭 UDP，脚本的诊断验证 TCP；应用层封装 UDP 需要另行配置支持它的客户端与协议。

## 诊断和验收

```bash
tcf-node diagnose
```

诊断通过临时 sing-box 客户端和 SOCKS 代理，执行真实 VLESS 请求：

1. 验证服务端配置。
2. 使用本地 WS + UUID 访问 Cloudflare trace，验证认证、DNS 和手机出站。
3. 使用域名 WSS/443 + 相同 UUID 访问 trace，验证域名、TLS、Tunnel、WS 和手机出站全链路。

诊断不会跳过 TLS 证书校验，输出目标网站看到的 `ip` 和 `loc`。临时客户端退出后会清理，仅监听本机随机端口。诊断可能需要约一分钟。

手机上的公网测试仍不能代替其他运营商网络的可达性测试。最后把分享链接导入另一台设备，实际访问一个出口 IP 查询页面，确认出口符合预期。手机若运行其他 VPN，系统路由也可能让出站流量进入那个 VPN；需要使用手机原生出口时，应检查这些路由设置。

常见问题：

| 现象 | 检查项 |
| --- | --- |
| 本地认证测试失败 | `tcf-node status`、`logs`，本地端口冲突、DNS 是否可达、手机能否访问目标网站 |
| 1033 / Tunnel disconnected | Tunnel 是否已连接、手机到 CF 的网络；可重新配置选择 `http2` |
| 502 | 控制台回源是否为 **HTTP**、`127.0.0.1:正确端口`，sing-box 是否运行 |
| 403、登录页、Challenge | Access、WAF 和域名规则是否适合普通代理客户端 |
| WS 404 或连接即断 | 客户端 Path 是否与脚本一致，域名是否指向正确 Tunnel |
| TLS 失败 | 域名、手机时间、DNS 和 Cloudflare 边缘证书是否已生效；不要关闭证书校验来掩盖问题 |
| 熄屏 / 重启后停止 | 电池设置、Termux:Boot 是否安装并打开过、是否已解锁；Android 可能结束整个 Termux |
| 软件包找不到 | 使用当前 Termux 和可用镜像，运行 `termux-change-repo` 后重试 |
| API 403 / Authentication error | API Token 是否有效、是否具备 Tunnel Edit / Zone Read / DNS Edit，资源范围是否包含正确账户和 Zone |
| 找不到 Zone | 域名是否已托管并激活，API Token 是否包含该 Zone 的 Read 权限 |
| DNS 冲突 | 使用未占用子域名，或自行处理已经存在的记录；脚本不会覆盖无关业务 |

仅 WS 握手成功并不能证明 UUID 正确或出站可用；以认证诊断与外部客户端验收为准。Cloudflare 维护或网络变化也可能中断 WS 连接，客户端应支持重连。

## 后台服务与开机启动

脚本使用 `termux-services` / runit，分别监督两个进程，异常退出会重启。它只操作以 `tcf-node-` 命名的两个服务。runit 守护进程使用 Termux 的标准服务目录。

开机启动需要：

1. 安装与 Termux **相同来源、相同签名体系**的 Termux:Boot。
2. 手动打开 Termux:Boot 一次。
3. 执行 `tcf-node boot-on`。
4. 将 Termux 和 Termux:Boot 的电池设置为不受限制。部分厂商还要求允许自启动、锁定后台；部分设备重启后需要先解锁。

脚本调用 `termux-wake-lock` 减少休眠影响，仍无法保证 Android 永不结束进程。`boot-off` 删除本脚本的启动文件；当前运行服务及 Termux 标准服务机制不受影响。如需让节点持续停止，请执行 `tcf-node stop`。本脚本不会调用全局 `termux-wake-unlock`，避免影响你在 Termux 中运行的其他任务。

## 文件与凭据

| 内容 | 位置 |
| --- | --- |
| 管理脚本、配置与凭据 | `~/.local/share/termux-cf-node/` |
| 当前生效配置 | `~/.local/share/termux-cf-node/current/` |
| 上一份配置 | `~/.local/share/termux-cf-node/previous/` |
| 自动创建资源的非秘密 ID | `~/.local/share/termux-cf-node/current/cloudflare.json` |
| 本机稳定标识（重试复用 Tunnel） | `~/.local/share/termux-cf-node/installation.id` |
| 分享链接 | `~/.local/share/termux-cf-node/current/node.txt` |
| Mihomo 片段 | `~/.local/share/termux-cf-node/current/clash-meta.json` |
| 本地服务日志 | `$PREFIX/var/log/sv/tcf-node-sing-box/` |
| Tunnel 日志 | `$PREFIX/var/log/sv/tcf-node-cloudflared/` |
| 开机脚本 | `~/.termux/boot/30-termux-cf-node` |
| 开机脚本输出 | `~/.local/share/termux-cf-node/boot.log` |

API Token 通过隐藏输入取得，只在配置期间写入私有临时 Header 文件，由 curl 从文件读取，不出现在命令行参数或导出的环境变量里。完成配置或正常退出失败流程后会清理，不写入配置备份。运行服务只保存权限为 `600` 的 Tunnel Token。配置保存在权限为 `700` 的私有目录中，最多保留当前和上一代完整配置。两代都可能包含 Tunnel Token；分享链接和二维码包含 UUID，也属于节点凭据。请在 Termux 私有目录运行，不要把整个配置目录复制到共享下载目录。

两个服务的日志按约 1 MiB 轮转，各保留最多 3 个归档。重新配置先生成并检查新配置，确认后配置 Cloudflare，再停止服务并切换整代配置；新配置不通时可以 `rollback`。涉及 API 管理的配置回退时，会重新请求 API Token，以同步远端回源和 DNS，避免只回退本地端口导致 502。正常启动 / 重启不需要 API Token。

`uninstall` 会删除本脚本的本地服务、配置、日志和开机脚本。它不会卸载共享的软件包，也不会删除 Cloudflare 上的 Tunnel / 域名记录。

## 官方参考

- [sing-box 的 Termux 安装](https://sing-box.sagernet.org/installation/package-manager/)
- [VLESS 入站](https://sing-box.sagernet.org/configuration/inbound/vless/)
- [WS 传输](https://sing-box.sagernet.org/configuration/shared/v2ray-transport/)
- [Cloudflare Tunnel 路由](https://developers.cloudflare.com/tunnel/concepts/routing/)
- [Tunnel 参数与 token-file](https://developers.cloudflare.com/tunnel/reference/run-parameters/)
- [通过 API 创建 Tunnel、配置回源和 DNS](https://developers.cloudflare.com/tunnel/get-started/)
- [Zone 查询权限](https://developers.cloudflare.com/api/resources/zones/methods/list/)
- [Termux:Boot](https://github.com/termux/termux-boot)
