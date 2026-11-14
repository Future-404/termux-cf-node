#!/data/data/com.termux/files/usr/bin/bash
# Termux + remotely managed Cloudflare Tunnel + sing-box VLESS/WS.
# Run: bash termux-cf-node.sh       Installed command: tcf-node
# No root, systemd, public listening port, or origin certificate required.

set -Eeuo pipefail
umask 077

VERSION=1.0.0
PREFIX=${PREFIX:-/data/data/com.termux/files/usr}
STATE="$HOME/.local/share/termux-cf-node"
CURRENT="$STATE/current"
SELF=$(realpath -- "${BASH_SOURCE[0]}")
SV_SB="$PREFIX/var/service/tcf-node-sing-box"
SV_CF="$PREFIX/var/service/tcf-node-cloudflared"
LOG_SB="$PREFIX/var/log/sv/tcf-node-sing-box"
LOG_CF="$PREFIX/var/log/sv/tcf-node-cloudflared"
BOOT="$HOME/.termux/boot/30-termux-cf-node"
TMP_WORK=''
PROBE_PID=''

say() { printf '%s\n' "$*"; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }
ask() {
    local input_name=$1 input_label=$2 input_default=${3:-} input_reply
    printf '%s' "$input_label" >&2
    [[ -z "$input_default" ]] || printf ' [%s]' "$input_default" >&2
    printf '：' >&2
    IFS= read -r input_reply || die '输入结束，操作已取消。'
    printf -v "$input_name" '%s' "${input_reply:-$input_default}"
}
confirm() {
    local answer
    ask answer "$1 (y/N)"
    [[ "$answer" == y || "$answer" == Y ]]
}
cleanup() {
    if [[ -n "$PROBE_PID" ]]; then
        kill "$PROBE_PID" 2>/dev/null || true
        wait "$PROBE_PID" 2>/dev/null || true
    fi
    [[ -z "$TMP_WORK" ]] || rm -rf -- "$TMP_WORK"
    return 0
}
check_termux() {
    [[ -d "$PREFIX" && -x "$PREFIX/bin/pkg" ]] || die '请在 Android 原生 Termux 中运行。'
    [[ $(id -u) != 0 ]] || die '请用普通 Termux 用户运行，不要使用 su 或 sudo。'
    export PATH="$PREFIX/bin:$PATH"
}
require_tools() {
    local tool
    for tool in jq sing-box cloudflared curl sv flock; do
        command -v "$tool" >/dev/null || die "缺少 $tool，请先执行安装/重新配置。"
    done
}
require_config() {
    [[ -f "$CURRENT/settings.json" && -s "$CURRENT/tunnel.token" ]] || die '尚未部署，请先选择安装/重新配置。'
}
setting() { jq -er --arg key "$1" '.[$key]' "$CURRENT/settings.json"; }
old_setting() {
    if [[ -f "$CURRENT/settings.json" ]]; then
        jq -er --arg key "$1" '.[$key] // empty' "$CURRENT/settings.json"
    else
        return 1
    fi
}
lock_action() {
    mkdir -p "$STATE"
    chmod 700 "$STATE"
    exec 9>"$STATE/manager.lock"
    flock -n 9 || die '另一个管理操作正在进行，请稍后重试。'
}
valid_domain() {
    local domain=$1 label
    [[ ${#domain} -le 253 && "$domain" == *.* ]] || return 1
    [[ "$domain" != *[!a-zA-Z0-9.-]* && "$domain" != *. ]] || return 1
    local -a labels
    IFS=. read -ra labels <<< "$domain"
    for label in "${labels[@]}"; do
        [[ ${#label} -ge 1 && ${#label} -le 63 && "$label" != -* && "$label" != *- ]] || return 1
    done
    [[ "${labels[-1]}" == *[a-zA-Z]* ]]
}
valid_uuid() { [[ "$1" =~ ^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$ ]]; }
valid_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] || return 1
    (( 10#$1 >= 1024 && 10#$1 <= 65535 ))
}
valid_path() { [[ "$1" =~ ^/[a-zA-Z0-9/_-]+$ && ${#1} -le 200 ]]; }
valid_dns() {
    local ip=$1 octet head tail group count=0 compressed=no
    if [[ "$ip" == *:* ]]; then
        [[ "$ip" =~ ^[a-fA-F0-9:]+$ && "$ip" != *:::* ]] || return 1
        if [[ "$ip" == *::* ]]; then
            compressed=yes
            head=${ip%%::*}
            tail=${ip#*::}
            [[ "$tail" != *::* ]] || return 1
        else
            head=$ip
            tail=''
        fi
        local -a groups
        for group in "$head" "$tail"; do
            [[ -n "$group" ]] || continue
            [[ "$group" != :* && "$group" != *: ]] || return 1
            IFS=: read -ra groups <<< "$group"
            for octet in "${groups[@]}"; do
                [[ "$octet" =~ ^[a-fA-F0-9]{1,4}$ ]] || return 1
                count=$((count + 1))
            done
        done
        if [[ "$compressed" == yes ]]; then (( count < 8 )); else (( count == 8 )); fi
    else
        [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
        local -a octets
        IFS=. read -ra octets <<< "$ip"
        for octet in "${octets[@]}"; do (( 10#$octet <= 255 )) || return 1; done
    fi
}
valid_token() {
    [[ "$1" =~ ^[a-zA-Z0-9+/=_-]+$ ]] || return 1
    printf '%s' "$1" | jq -eRs '
        @base64d | fromjson |
        (.a | type == "string" and length > 0) and
        (.t | type == "string" and length > 0) and
        (.s | type == "string" and length > 0)
    ' >/dev/null 2>&1
}
read_token() {
    local destination=$1 allow_keep=${2:-no} value
    while true; do
        printf '粘贴 Tunnel Token（隐藏输入%s）：' "$( [[ "$allow_keep" == yes ]] && printf '，回车保留' )" >&2
        IFS= read -rs value || die '输入结束。'
        printf '\n' >&2
        if [[ -z "$value" && "$allow_keep" == yes ]]; then
            cp -- "$CURRENT/tunnel.token" "$destination"
            return
        fi
        if valid_token "$value"; then
            printf '%s' "$value" > "$destination"
            chmod 600 "$destination"
            unset value
            return
        fi
        say '格式不正确。请只粘贴 Tunnel Token，不要粘贴整条安装命令或 Cloudflare API Token。'
    done
}
generate_server() {
    local metadata=$1 destination=$2
    jq '{
        log: {level: "warn", timestamp: true},
        dns: {servers: [{type: "udp", tag: "upstream", server: .dns}]},
        inbounds: [{
            type: "vless", tag: "vless-ws", listen: "127.0.0.1", listen_port: .port,
            users: [{name: "phone", uuid: .uuid}],
            transport: {type: "ws", path: .path}
        }],
        outbounds: [{type: "direct", tag: "direct"}],
        route: {final: "direct", default_domain_resolver: "upstream"}
    }' "$metadata" > "$destination"
}
generate_exports() {
    local directory=$1
    jq -r '
        "vless://" + .uuid + "@" + .domain + ":443?encryption=none&security=tls&type=ws&host=" +
        (.domain | @uri) + "&sni=" + (.domain | @uri) + "&path=" + (.path | @uri) + "#" + (.name | @uri)
    ' "$directory/settings.json" > "$directory/node.txt"
    jq '{proxies: [{
        name: .name, type: "vless", server: .domain, port: 443, uuid: .uuid,
        tls: true, servername: .domain, network: "ws", udp: false,
        "ws-opts": {path: .path, headers: {Host: .domain}}
    }]}' "$directory/settings.json" > "$directory/clash-meta.json"
}
show_guide() {
    local domain=$1 port=$2
    cat <<EOF

Cloudflare 控制台一次性配置：
  1. 域名托管到 Cloudflare，进入 Cloudflare One / Zero Trust 的 Tunnels。
  2. 创建 cloudflared 类型的 Tunnel，复制安装命令里的 Tunnel Token。
  3. 为该 Tunnel 添加 Published application / Public hostname：
       Hostname : $domain
       Type     : HTTP
       URL      : 127.0.0.1:$port
       Path     : 留空（节点的 WS Path 由手机服务端检查）
  4. 保存后，确认域名路由和 Tunnel 状态。手机无需开放入站端口。

节点客户端使用域名的 443/WSS；手机本地使用 HTTP/WS。
普通代理客户端无法完成 Cloudflare Access 的浏览器登录，请使用兼容的访问策略。
本脚本不使用 Cloudflare API，因此以上远程创建和域名映射需要你在控制台完成。
EOF
}
install_manager() {
    if [[ "$SELF" != "$STATE/manage.sh" ]]; then
        cp -- "$SELF" "$STATE/.manage.sh.new"
        chmod 700 "$STATE/.manage.sh.new"
        mv -f -- "$STATE/.manage.sh.new" "$STATE/manage.sh"
    fi
    {
        printf '#!%s/bin/bash\n' "$PREFIX"
        printf 'exec %q %q "$@"\n' "$PREFIX/bin/bash" "$STATE/manage.sh"
    } > "$PREFIX/bin/tcf-node"
    chmod 700 "$PREFIX/bin/tcf-node"
}
write_services() {
    local service log
    mkdir -p "$SV_SB/log" "$SV_CF/log" "$LOG_SB" "$LOG_CF"
    # Explicit empty local configuration isolates unrelated ~/.cloudflared/config.yml.
    printf '{}\n' > "$STATE/tunnel-local.yml"
    touch "$SV_SB/down" "$SV_CF/down"
    {
        printf '#!%s/bin/bash\nset -eu\nexec 2>&1\n' "$PREFIX"
        printf 'export HOME=%q PATH=%q\n' "$HOME" "$PREFIX/bin:/system/bin"
        printf 'exec %q run -c %q\n' "$PREFIX/bin/sing-box" "$CURRENT/server.json"
    } > "$SV_SB/run"
    {
        printf '#!%s/bin/bash\nset -eu\nexec 2>&1\n' "$PREFIX"
        printf 'export HOME=%q PATH=%q\n' "$HOME" "$PREFIX/bin:/system/bin"
        # Token goes through a file, never a command-line argument or environment.
        printf 'unset TUNNEL_TOKEN TUNNEL_TOKEN_FILE\n'
        # These variables expand in the generated service, not during installation.
        # shellcheck disable=SC2016
        printf 'protocol=$(%q -er .protocol %q)\n' "$PREFIX/bin/jq" "$CURRENT/settings.json"
        # Explicit DNS avoids depending on Android's inaccessible system resolver list.
        # shellcheck disable=SC2016
        printf 'dns=$(%q -er .dns %q)\n' "$PREFIX/bin/jq" "$CURRENT/settings.json"
        # shellcheck disable=SC2016
        printf 'if [[ "$dns" == *:* ]]; then dns="[$dns]:53"; else dns="$dns:53"; fi\n'
        # shellcheck disable=SC2016
        printf 'exec %q tunnel --config %q --no-autoupdate --edge-ip-version auto --protocol "$protocol" --metrics 127.0.0.1:0 --grace-period 2s run --dns-resolver-addrs "$dns" --token-file %q\n' \
            "$PREFIX/bin/cloudflared" "$STATE/tunnel-local.yml" "$CURRENT/tunnel.token"
    } > "$SV_CF/run"
    for service in "$SV_SB" "$SV_CF"; do
        if [[ "$service" == "$SV_SB" ]]; then log=$LOG_SB; else log=$LOG_CF; fi
        {
            printf '#!%s/bin/bash\n' "$PREFIX"
            printf 'exec %q -tt %q\n' "$PREFIX/bin/svlogd" "$log"
        } > "$service/log/run"
        printf 's1048576\nn3\n' > "$log/config"
        chmod 700 "$service/run" "$service/log/run"
    done
}
ensure_supervisor() {
    local attempt
    # Do not leak the manager's flock descriptor into the persistent daemon.
    ( exec 9>&-; export SVDIR="$PREFIX/var/service" LOGDIR="$PREFIX/var/log";
      service-daemon start >/dev/null 2>&1 || true )
    for ((attempt=0; attempt<50; attempt++)); do
        if [[ -p "$SV_SB/supervise/control" && -p "$SV_CF/supervise/control" ]]; then return; fi
        sleep 0.2
    done
    die 'runit 尚未接管服务。请重新打开 Termux 后执行 tcf-node start。'
}
stop_services() {
    local service
    for service in "$SV_CF" "$SV_SB"; do
        [[ -d "$service" ]] || continue
        touch "$service/down"
        if [[ -p "$service/supervise/control" ]]; then
            sv -w 12 down "$service" || die "无法停止 $service；配置尚未替换。"
        fi
    done
}
ws_probe() {
    local url=$1 code
    # A WS connection stays open; timeout after a 101 response is expected.
    code=$(curl --noproxy '*' --http1.1 --silent --output /dev/null --write-out '%{http_code}' \
        --connect-timeout 2 --max-time 3 -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
        -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "$url" 2>/dev/null) || true
    [[ "$code" == 101 ]]
}
start_services() {
    require_config
    sing-box check -c "$CURRENT/server.json"
    [[ -x "$SV_SB/run" && -x "$SV_CF/run" ]] || die '服务文件缺失，请重新配置。'
    ensure_supervisor
    if command -v termux-wake-lock >/dev/null; then termux-wake-lock || true; fi
    rm -f "$SV_SB/down"
    sv -w 10 up "$SV_SB"
    sleep 1
    if ! ws_probe "http://127.0.0.1:$(setting port)$(setting path)"; then
        say '本地 WS 检查失败，停止本节点服务。请查看 tcf-node logs。'
        stop_services
        return 1
    fi
    rm -f "$SV_CF/down"
    sv -w 10 up "$SV_CF"
    say '本地 WS 已响应；Tunnel 进程已启动，连接 Cloudflare 可能需要几十秒。'
    say '请执行 tcf-node diagnose 测试认证和公网全链路，进程启动不代表公网部署成功。'
}
activate_generation() {
    local staged=$1 previous='' target
    mkdir -p "$STATE/releases"
    [[ ! -L "$CURRENT" ]] || previous=$(readlink "$CURRENT")
    target=${staged##*/}
    target="releases/config-${target#.stage.}"
    stop_services
    mv -- "$staged" "$STATE/$target"
    TMP_WORK=''
    ln -sfn -- "$target" "$STATE/.current.new"
    mv -Tf -- "$STATE/.current.new" "$CURRENT"
    if [[ -n "$previous" ]]; then
        ln -sfn -- "$previous" "$STATE/previous"
    fi
    # Keep at most current and previous generation; both contain credentials.
    local release
    for release in "$STATE/releases"/*; do
        [[ -d "$release" ]] || continue
        if [[ "$release" != "$STATE/$target" && "$release" != "$STATE/$previous" ]]; then
            rm -rf -- "$release"
        fi
    done
}
configure() {
    local domain port uuid path name protocol dns cf_help keep=no
    say '将从 Termux 软件源安装 sing-box、cloudflared、runit 管理及必要工具。'
    pkg update -y
    pkg install -y sing-box cloudflared termux-services jq curl util-linux coreutils
    require_tools
    lock_action
    cf_help=$(cloudflared tunnel run --help)
    if [[ "$cf_help" != *--token-file* || "$cf_help" != *--dns-resolver-addrs* ]]; then
        die 'cloudflared 需要支持 --token-file 和 --dns-resolver-addrs（2025.7.0 或更新），请更新 Termux 软件源。'
    fi
    while true; do
        ask domain '节点域名，例如 node.example.com' "$(old_setting domain || true)"
        domain=${domain,,}
        valid_domain "$domain" && break
        say '请输入完整域名，不含 https://、端口、路径或通配符。'
    done
    while true; do
        ask port '手机本地监听端口' "$(old_setting port || printf 8080)"
        if valid_port "$port"; then port=$((10#$port)); break; fi
        say '端口需为 1024～65535 的整数。'
    done
    while true; do
        ask uuid 'VLESS UUID（回车使用默认值）' "$(old_setting uuid || sing-box generate uuid)"
        valid_uuid "$uuid" && break
        say 'UUID 格式不正确。'
    done
    while true; do
        ask path 'WebSocket 路径' "$(old_setting path || printf '/%s' "$(sing-box generate uuid | tr -d '-')")"
        valid_path "$path" && break
        say '路径须以 / 开头，仅使用字母、数字、/、_、-，最长 200 字符。'
    done
    ask name '节点名称' "$(old_setting name || printf '手机出口')"
    while true; do
        ask protocol 'Tunnel 传输协议 auto/http2/quic' "$(old_setting protocol || printf auto)"
        [[ "$protocol" == auto || "$protocol" == http2 || "$protocol" == quic ]] && break
        say '请输入 auto、http2 或 quic。UDP 不通时可以选择 http2。'
    done
    while true; do
        ask dns '节点和 Tunnel 使用的 DNS IP（UDP/53，纯 IPv6 网络请填可达 IPv6 DNS）' "$(old_setting dns || printf 1.1.1.1)"
        valid_dns "$dns" && break
        say '请输入 DNS 服务器的 IPv4 或 IPv6 地址。'
    done
    show_guide "$domain" "$port"
    TMP_WORK=$(mktemp -d "$STATE/.stage.XXXXXXXX")
    [[ ! -s "$CURRENT/tunnel.token" ]] || keep=yes
    read_token "$TMP_WORK/tunnel.token" "$keep"
    jq -n --arg domain "$domain" --argjson port "$port" --arg uuid "$uuid" --arg path "$path" \
        --arg name "$name" --arg protocol "$protocol" --arg dns "$dns" \
        '{domain:$domain, port:$port, uuid:$uuid, path:$path, name:$name, protocol:$protocol, dns:$dns}' \
        > "$TMP_WORK/settings.json"
    generate_server "$TMP_WORK/settings.json" "$TMP_WORK/server.json"
    generate_exports "$TMP_WORK"
    sing-box check -c "$TMP_WORK/server.json"
    if ! confirm '保存配置并启动本节点'; then say '已取消，原配置和原服务保持原状。'; return; fi
    activate_generation "$TMP_WORK"
    install_manager
    write_services
    start_services
    show_node
    if confirm '生成 Termux:Boot 开机启动脚本'; then enable_boot; fi
}
show_node() {
    require_config
    say "域名：$(setting domain):443    传输：WS + TLS"
    say "本地：127.0.0.1:$(setting port)    WS Path：$(setting path)"
    say '分享链接（包含节点凭据）：'
    cat "$CURRENT/node.txt"
    say "链接文件：$CURRENT/node.txt"
    say "Clash Meta/Mihomo proxies 片段（JSON 可作为 YAML 使用）：$CURRENT/clash-meta.json"
    if command -v qrencode >/dev/null; then
        qrencode -t ANSIUTF8 < "$CURRENT/node.txt"
    else
        say '如需终端二维码：pkg install qrencode，然后执行 tcf-node node。'
    fi
}
show_status() {
    require_config
    say "版本：$VERSION    域名：$(setting domain)    Tunnel 协议：$(setting protocol)"
    say '以下仅表示本机进程状态；请用 diagnose 验证公网全链路：'
    local service
    for service in "$SV_SB" "$SV_CF"; do
        if [[ -p "$service/supervise/control" ]]; then sv status "$service" || true
        else say "未被 runit 接管：${service##*/}"; fi
    done
    if [[ -f "$BOOT" ]]; then say '开机启动脚本：已生成（仍需安装并打开一次 Termux:Boot）'
    else say '开机启动脚本：未生成'; fi
}
enable_boot() {
    require_config
    mkdir -p "$(dirname "$BOOT")"
    {
        printf '#!%s/bin/bash\n' "$PREFIX"
        printf 'export HOME=%q PREFIX=%q PATH=%q\n' "$HOME" "$PREFIX" "$PREFIX/bin:/system/bin"
        printf 'exec %q %q start >> %q 2>&1\n' "$PREFIX/bin/bash" "$STATE/manage.sh" "$STATE/boot.log"
    } > "$BOOT"
    chmod 700 "$BOOT"
    say '已生成开机脚本。请安装与 Termux 同来源的 Termux:Boot，并打开它一次。'
    say '将 Termux 和 Termux:Boot 的电池设为不受限制；部分系统重启后需先解锁。'
}
change_token() {
    require_config
    TMP_WORK=$(mktemp -d "$STATE/.stage.XXXXXXXX")
    cp -- "$CURRENT/"{settings.json,server.json,node.txt,clash-meta.json} "$TMP_WORK/"
    read_token "$TMP_WORK/tunnel.token"
    activate_generation "$TMP_WORK"
    start_services
    say 'Token 已替换。更换到其他 Tunnel 后，仍需在该 Tunnel 配置相同域名映射。'
}
rollback() {
    [[ -L "$STATE/previous" && -d "$STATE/previous" ]] || die '没有上一份配置。'
    confirm '回退到上一份配置并重启节点' || return 0
    local previous current
    previous=$(readlink "$STATE/previous")
    current=$(readlink "$CURRENT")
    sing-box check -c "$STATE/previous/server.json"
    stop_services
    ln -sfn -- "$previous" "$STATE/.current.new"
    mv -Tf -- "$STATE/.current.new" "$CURRENT"
    ln -sfn -- "$current" "$STATE/previous"
    start_services
    show_node
}
show_logs() {
    local log
    for log in "$LOG_SB/current" "$LOG_CF/current"; do
        say "--- $log ---"
        if [[ -f "$log" ]]; then tail -n 60 "$log"; else say '尚无日志。'; fi
    done
}
generate_probe() {
    local settings=$1 destination=$2 port=$3 mode=$4
    jq --argjson local_port "$port" --arg mode "$mode" '{
        log: {level:"warn"},
        dns: {servers:[{type:"udp", tag:"upstream", server:.dns}]},
        inbounds:[{type:"socks", listen:"127.0.0.1", listen_port:$local_port}],
        outbounds:[{
            type:"vless", tag:"node",
            server:(if $mode == "local" then "127.0.0.1" else .domain end),
            server_port:(if $mode == "local" then .port else 443 end), uuid:.uuid,
            transport:{type:"ws", path:.path},
            tls:{enabled:($mode != "local"), server_name:.domain}
        }],
        route:{final:"node", default_domain_resolver:"upstream"}
    }' "$settings" > "$destination"
}
authenticated_probe() {
    local mode=$1 port attempt result='' rc=1
    for ((attempt=0; attempt<3; attempt++)); do
        port=$(shuf -i 20000-60000 -n 1)
        generate_probe "$CURRENT/settings.json" "$TMP_WORK/client.json" "$port" "$mode"
        sing-box check -c "$TMP_WORK/client.json" > "$TMP_WORK/check.log" 2>&1 || return 1
        sing-box run -c "$TMP_WORK/client.json" > "$TMP_WORK/client.log" 2>&1 &
        PROBE_PID=$!
        sleep 1
        if kill -0 "$PROBE_PID" 2>/dev/null; then break; fi
        wait "$PROBE_PID" 2>/dev/null || true
        PROBE_PID=''
    done
    [[ -n "$PROBE_PID" ]] || return 1
    # Explicit proxy and empty noproxy prevent inherited proxy env from bypassing this test.
    if result=$(curl --silent --show-error --fail --proxy "socks5h://127.0.0.1:$port" --noproxy '' \
        --connect-timeout 10 --max-time 25 https://www.cloudflare.com/cdn-cgi/trace 2>"$TMP_WORK/curl.log"); then
        if [[ "$result" == *$'\nip='* ]]; then
            printf '%s\n' "$result" | sed -n '/^ip=/p; /^loc=/p'
            rc=0
        fi
    fi
    kill "$PROBE_PID" 2>/dev/null || true
    wait "$PROBE_PID" 2>/dev/null || true
    PROBE_PID=''
    return "$rc"
}
diagnose() {
    require_config
    TMP_WORK=$(mktemp -d "$STATE/.probe.XXXXXXXX")
    say '1/3 检查服务端配置'
    sing-box check -c "$CURRENT/server.json"
    say '2/3 本地认证测试：SOCKS → VLESS/WS → 手机出站 → Cloudflare trace'
    if authenticated_probe local; then say '本地认证与手机出站：通过'
    else
        say '本地认证或出站失败。检查服务、DNS 和手机网络；诊断客户端日志：'
        tail -n 12 "$TMP_WORK/client.log" "$TMP_WORK/curl.log" 2>/dev/null || true
        return 1
    fi
    say '3/3 公网全链路：SOCKS → 域名 WSS/443 → Tunnel → 手机 VLESS → 目标网站'
    if authenticated_probe public; then
        say '公网认证全链路：通过。上述 ip 为目标网站看到的实际出口。'
        say '本机回环测试不代替其他网络的可达性测试，请再从外部客户端连接一次。'
    else
        say '公网全链路失败。请等待 DNS/证书生效，并检查 Tunnel 日志和控制台域名映射。'
        say '重点排查：1033=Tunnel 未连接；502=本地端口错误；403/登录页=Access 或 WAF。'
        tail -n 12 "$TMP_WORK/client.log" "$TMP_WORK/curl.log" 2>/dev/null || true
        return 1
    fi
}
uninstall_node() {
    confirm '删除本节点的本地服务、配置、Token、日志和开机脚本（不可恢复）' || return 0
    stop_services
    local service
    for service in "$SV_CF" "$SV_SB"; do
        if [[ -p "$service/supervise/control" ]]; then sv -w 10 exit "$service" || die '服务管理进程退出失败，请稍后重试。'; fi
        rm -rf -- "$service"
    done
    rm -f -- "$BOOT" "$PREFIX/bin/tcf-node"
    rm -rf -- "$LOG_SB" "$LOG_CF" "$STATE"
    say '本地节点已卸载。已安装的软件包保留；Cloudflare 上的 Tunnel/域名映射需在控制台删除。'
}
menu() {
    local choice action
    while true; do
        cat <<EOF

Termux Cloudflare VLESS/WS 节点 v$VERSION
  1) 安装 / 重新配置        2) 启动
  3) 停止                 4) 重启
  5) 进程状态             6) 分享链接 / 二维码
  7) 本地 / 公网诊断       8) 查看日志
  9) 更换 Tunnel Token   10) 启用开机启动
 11) 关闭开机启动        12) Cloudflare 配置指引
 13) 回退上一份配置      14) 卸载本地节点
  0) 退出
EOF
        ask choice '请选择'
        case "$choice" in
            1) action=install ;; 2) action=start ;; 3) action=stop ;; 4) action=restart ;;
            5) action=status ;; 6) action=node ;; 7) action=diagnose ;; 8) action=logs ;;
            9) action=token ;; 10) action=boot-on ;; 11) action=boot-off ;; 12) action=guide ;;
            13) action=rollback ;; 14) action=uninstall ;; 0) return ;; *) say '无效选项。'; continue ;;
        esac
        # New Bash keeps errexit active in actions, even though menu handles their exit status.
        if "$BASH" "$SELF" "$action"; then :; else say '操作未完成，请查看上面的错误信息。'; fi
    done
}
main() {
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'printf "操作失败（第 %s 行），请检查上面的错误；原有配置可用 rollback 回退。\n" "$LINENO" >&2' ERR
    case "${1:-menu}" in
        -h|--help|help)
            say '用法：bash termux-cf-node.sh [install|start|stop|restart|status|node|diagnose|logs|token|boot-on|boot-off|guide|rollback|uninstall]'
            return ;;
    esac
    check_termux
    case "${1:-menu}" in
        menu) menu ;;
        install|configure) configure ;;
        start) require_tools; lock_action; start_services ;;
        stop) require_tools; lock_action; stop_services; say '本节点服务已停止；再次 start 前不会自动恢复。' ;;
        restart) require_tools; lock_action; stop_services; start_services ;;
        status) require_tools; show_status ;;
        node) require_tools; show_node ;;
        diagnose) require_tools; lock_action; diagnose ;;
        logs) show_logs ;;
        token) require_tools; lock_action; change_token ;;
        boot-on) require_tools; lock_action; enable_boot ;;
        boot-off) rm -f -- "$BOOT"; say '已删除本节点开机脚本，当前服务保持运行。' ;;
        guide) require_tools; require_config; show_guide "$(setting domain)" "$(setting port)" ;;
        rollback) require_tools; lock_action; rollback ;;
        uninstall) require_tools; lock_action; uninstall_node ;;
        *) die '未知命令。使用 --help 查看用法。' ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
