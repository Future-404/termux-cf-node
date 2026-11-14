#!/data/data/com.termux/files/usr/bin/bash
# Termux + remotely managed Cloudflare Tunnel + sing-box VLESS/WS.
# Run: bash termux-cf-node.sh       Installed command: tcf-node
# No root, systemd, public listening port, or origin certificate required.

set -Eeuo pipefail
umask 077

VERSION=1.1.0
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
read_api_token() {
    local destination=$1 value
    say 'API Token 权限：Account / Cloudflare Tunnel / Edit；Zone / Zone / Read；Zone / DNS / Edit。'
    say '资源范围需包含节点域名及其所属账户。输入 API Token，脚本会自动创建/配置 Tunnel 和 DNS。'
    while true; do
        printf '粘贴 Cloudflare API Token（隐藏输入）：' >&2
        IFS= read -rs value || die '输入结束。'
        printf '\n' >&2
        if valid_token "$value"; then
            say '这是用于连接已有 Tunnel 的 Tunnel Token；自动部署需要有上述权限的 API Token。'
        elif [[ "$value" =~ ^[a-zA-Z0-9._~-]{20,}$ ]]; then
            printf 'Authorization: Bearer %s\n' "$value" > "$destination"
            chmod 600 "$destination"
            unset value
            return
        else
            say '格式不正确。请只粘贴 API Token，不要粘贴安装命令、Global API Key 或 Bearer 前缀。'
        fi
    done
}
cf_api() {
    local method=$1 path=$2 output=$3 body=${4:-} code
    local -a args=(--disable --silent --show-error --proto '=https' --connect-timeout 10 --max-time 30
        --request "$method" --header "@${CF_AUTH_FILE:?}" --header 'Content-Type: application/json'
        --output "$output" --write-out '%{http_code}')
    # Retry reads only. Retrying a timed-out POST could create duplicate resources.
    [[ "$method" != GET ]] || args+=(--retry 2 --retry-delay 1)
    [[ -z "$body" ]] || args+=(--data-binary "@$body")
    if ! code=$(curl "${args[@]}" "https://api.cloudflare.com/client/v4$path"); then
        say "Cloudflare API 网络请求失败：$method ${path%%\?*}；可重新运行以恢复未完成的部署。" >&2
        CF_HTTP_STATUS=${code:-000}
        return 1
    fi
    CF_HTTP_STATUS=$code
    if [[ "$code" != 2?? ]] || ! jq -e '.success == true' "$output" >/dev/null 2>&1; then
        say "Cloudflare API 失败：HTTP $code，$method ${path%%\?*}" >&2
        jq -r '.errors[]? | "  错误 \(.code): \(.message)"' "$output" >&2 2>/dev/null || true
        return 1
    fi
}
cf_find_zone() {
    local domain=$1 output=$2 candidate=$1 count
    # Exact suffix queries choose the most specific accessible zone, including co.uk / subzones.
    while [[ "$candidate" == *.* ]]; do
        cf_api GET "/zones?name=$candidate&per_page=50" "$output" || return 1
        count=$(jq --arg name "$candidate" '[.result[] | select(.name == $name)] | length' "$output") || return 1
        if ((count > 0)); then
            if [[ "$count" != 1 ]] || ! jq -e '.result[0].status == "active"' "$output" >/dev/null; then
                say "域名 Zone $candidate 不唯一或尚未激活，请检查域名授权及托管状态。" >&2
                return 1
            fi
            jq --arg name "$candidate" '.result[] | select(.name == $name)' "$output" > "$output.zone" || return 1
            mv -f -- "$output.zone" "$output"
            return
        fi
        candidate=${candidate#*.}
    done
    say "找不到 $domain 对应的 Zone。请检查 Zone Read 权限、资源范围及域名托管状态。" >&2
    return 1
}
cf_token_ids() {
    local file=$1
    [[ -s "$file" ]] || return 1
    jq -eRs '@base64d | fromjson | select((.a | test("^[a-fA-F0-9]{32}$")) and (.t | test("^[a-fA-F0-9-]{36}$"))) | {account_id:.a,tunnel_id:.t}' "$file" 2>/dev/null
}
cf_build_ingress() {
    local original=$1 domain=$2 port=$3 output=$4
    jq --arg host "$domain" --arg service "http://127.0.0.1:$port" '
        (.result.config // {}) |
        (.ingress // []) as $old |
        (if ($old | length) == 0 then [{service:"http_status:404"}] else $old end) as $rules |
        if (($rules[-1].hostname // "") != "" or ($rules[-1].path // "") != "") then
            error("Tunnel 配置缺少最后一条 catch-all 规则")
        elif any($rules[]; .hostname == $host and (.path // "") != "") then
            error("该域名已有按路径路由的规则，请使用独立节点域名")
        else
            ($rules | map(select(.hostname != $host))) as $keep |
            .ingress = ($keep[:-1] + [{hostname:$host,service:$service,originRequest:{}}] + $keep[-1:]) |
            {config:.}
        end
    ' "$original" > "$output"
}
cf_provision() {
    local staged=$1 api_dir domain port account zone tunnel='' tunnel_name install_id digest
    local existing=false dns_id='' target current_target='' record_count file ids token candidate
    local CF_AUTH_FILE CF_HTTP_STATUS=''
    api_dir="$staged/.api"
    mkdir -p "$api_dir"
    CF_AUTH_FILE="$api_dir/auth.header"
    read_api_token "$CF_AUTH_FILE"
    domain=$(jq -er .domain "$staged/settings.json") || return 1
    port=$(jq -er .port "$staged/settings.json") || return 1
    cf_find_zone "$domain" "$api_dir/zone.json" || return 1
    account=$(jq -er .account.id "$api_dir/zone.json") || return 1
    zone=$(jq -er .id "$api_dir/zone.json") || return 1
    [[ "$account" =~ ^[a-fA-F0-9]{32}$ && "$zone" =~ ^[a-fA-F0-9]{32}$ ]] || return 1
    say "已识别 Zone：$(jq -r .name "$api_dir/zone.json")；账户：$account"

    # Reuse the connector from this generation / current domain, including pre-1.1 installs.
    # Reading an existing connector token is not the same as storing the API token.
    for file in "$staged/tunnel.token" "$CURRENT/tunnel.token"; do
        if [[ "$file" == "$CURRENT/tunnel.token" && "$(old_setting domain || true)" != "$domain" ]]; then continue; fi
        if ids=$(cf_token_ids "$file"); then
            if [[ $(jq -r .account_id <<< "$ids") == "$account" ]]; then
                tunnel=$(jq -r .tunnel_id <<< "$ids")
                break
            fi
        fi
    done
    if [[ ! -f "$STATE/installation.id" ]]; then
        sing-box generate uuid > "$STATE/installation.id" || return 1
    fi
    install_id=$(cat "$STATE/installation.id")
    valid_uuid "$install_id" || return 1
    digest=$(printf '%s' "$domain" | sha256sum) || return 1
    tunnel_name="tcf-node-$install_id-${digest:0:12}"
    if [[ -n "$tunnel" ]]; then
        cf_api GET "/accounts/$account/cfd_tunnel/$tunnel" "$api_dir/tunnel.json" || return 1
        jq -e '.result.config_src == "cloudflare" and (.result.deleted_at == null)' "$api_dir/tunnel.json" >/dev/null || {
            say '已有 Tunnel 不是可用的远程管理 Tunnel，请使用其他子域名部署。' >&2; return 1;
        }
        existing=true
    else
        cf_api GET "/accounts/$account/cfd_tunnel?name=$tunnel_name&is_deleted=false&per_page=100" "$api_dir/tunnels.json" || return 1
        candidate=$(jq -er --arg name "$tunnel_name" '[.result[] | select(.name == $name and .deleted_at == null)] |
            if length > 1 then error("多个同名 Tunnel") else .[0].id // empty end' "$api_dir/tunnels.json") || {
            # An empty result is expected on the first run; malformed / ambiguous data is not.
            jq -e --arg name "$tunnel_name" '[.result[] | select(.name == $name and .deleted_at == null)] | length == 0' "$api_dir/tunnels.json" >/dev/null || return 1
            candidate=''
        }
        if [[ -n "$candidate" ]]; then tunnel=$candidate; existing=true; fi
    fi
    [[ -z "$tunnel" ]] || valid_uuid "$tunnel" || return 1

    # Inspect DNS before creating anything. Only this phone's known connector may be replaced.
    cf_api GET "/zones/$zone/dns_records?name=$domain&per_page=100" "$api_dir/dns.json" || return 1
    record_count=$(jq --arg name "$domain" '[.result[] | select(.name == $name)] | length' "$api_dir/dns.json") || return 1
    if ((record_count > 0)); then
        if [[ "$(old_setting domain || true)" == "$domain" ]] && ids=$(cf_token_ids "$CURRENT/tunnel.token"); then
            if [[ $(jq -r .account_id <<< "$ids") == "$account" ]]; then
                current_target="$(jq -r .tunnel_id <<< "$ids").cfargotunnel.com"
            fi
        fi
        target="${tunnel:-not-created}.cfargotunnel.com"
        if [[ "$record_count" != 1 ]] || ! jq -e --arg target "$target" --arg previous "$current_target" '
            .result[0] | .type == "CNAME" and
            ((.content | ascii_downcase | rtrimstr(".")) == $target or
             ($previous != "" and (.content | ascii_downcase | rtrimstr(".")) == $previous))
        ' "$api_dir/dns.json" >/dev/null; then
            say "DNS 冲突：$domain 已有不属于本节点的记录；未覆盖，请使用未占用的子域名。" >&2
            return 1
        fi
        dns_id=$(jq -er .result[0].id "$api_dir/dns.json") || return 1
    fi
    if [[ "$existing" == false ]]; then
        jq -n --arg name "$tunnel_name" '{name:$name,config_src:"cloudflare"}' > "$api_dir/create.json" || return 1
        cf_api POST "/accounts/$account/cfd_tunnel" "$api_dir/tunnel.json" "$api_dir/create.json" || return 1
        tunnel=$(jq -er .result.id "$api_dir/tunnel.json") || return 1
        valid_uuid "$tunnel" || return 1
        say "已创建 Tunnel：$tunnel。中途失败时重新运行会复用该 Tunnel。"
        printf '{"result":{"config":{}}}\n' > "$api_dir/original.json"
    else
        say "复用已有 Tunnel：$tunnel"
        if ! cf_api GET "/accounts/$account/cfd_tunnel/$tunnel/configurations" "$api_dir/original.json"; then
            [[ "$CF_HTTP_STATUS" == 404 ]] || return 1
            printf '{"result":{"config":{}}}\n' > "$api_dir/original.json"
        fi
    fi
    cf_api GET "/accounts/$account/cfd_tunnel/$tunnel/token" "$api_dir/token.json" || return 1
    token=$(jq -er '.result | strings' "$api_dir/token.json") || return 1
    valid_token "$token" || { say 'Cloudflare 返回了无效的 Tunnel Token。' >&2; return 1; }
    printf '%s' "$token" > "$staged/tunnel.token"
    unset token
    cf_build_ingress "$api_dir/original.json" "$domain" "$port" "$api_dir/config.json" || return 1
    cf_api PUT "/accounts/$account/cfd_tunnel/$tunnel/configurations" "$api_dir/config-result.json" "$api_dir/config.json" || return 1
    target="$tunnel.cfargotunnel.com"
    jq -n --arg host "$domain" --arg target "$target" '{type:"CNAME",name:$host,content:$target,proxied:true,ttl:1}' > "$api_dir/record.json" || return 1
    if [[ -z "$dns_id" ]]; then
        if cf_api POST "/zones/$zone/dns_records" "$api_dir/record-result.json" "$api_dir/record.json"; then
            dns_id=$(jq -er .result.id "$api_dir/record-result.json") || return 1
        else
            cf_restore_config "$account" "$tunnel" "$api_dir"
            return 1
        fi
    elif ! cf_api PATCH "/zones/$zone/dns_records/$dns_id" "$api_dir/record-result.json" "$api_dir/record.json"; then
        cf_restore_config "$account" "$tunnel" "$api_dir"
        return 1
    fi
    jq -n --arg account_id "$account" --arg zone_id "$zone" --arg tunnel_id "$tunnel" --arg dns_id "$dns_id" \
        '{account_id:$account_id,zone_id:$zone_id,tunnel_id:$tunnel_id,dns_id:$dns_id}' > "$staged/cloudflare.json" || return 1
    jq '.provisioning="api"' "$staged/settings.json" > "$api_dir/settings.json" || return 1
    mv -f -- "$api_dir/settings.json" "$staged/settings.json" || return 1
    rm -rf -- "$api_dir"
    say "Cloudflare 已配置：$domain → $target → http://127.0.0.1:$port"
}
cf_restore_config() {
    local account=$1 tunnel=$2 api_dir=$3
    jq '{config:(if (.result.config.ingress // [] | length) > 0 then .result.config else {ingress:[{service:"http_status:404"}]} end)}' \
        "$api_dir/original.json" > "$api_dir/restore.json" || return 1
    if cf_api PUT "/accounts/$account/cfd_tunnel/$tunnel/configurations" "$api_dir/restore-result.json" "$api_dir/restore.json"; then
        say 'DNS 写入失败，已恢复修改前的 Tunnel 回源配置；可修正权限后重试。' >&2
    else
        say "DNS 写入失败且回源恢复未成功；请重新运行部署修复 Tunnel $tunnel。" >&2
    fi
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

自动部署只需：已托管到 Cloudflare 的域名，以及一个 API Token。
  Token 权限：Account / Cloudflare Tunnel / Edit
              Zone / Zone / Read
              Zone / DNS / Edit
  资源范围：包括节点域名及其所属账户。

脚本将自动识别账户和 Zone，创建/复用 Tunnel，并配置：
  Hostname : $domain
  Type     : HTTP
  URL      : 127.0.0.1:$port
  DNS      : proxied CNAME → Tunnel
无需在网页端手动创建 Tunnel 或添加域名映射。

节点客户端使用域名的 443/WSS；手机本地使用 HTTP/WS。
普通代理客户端无法完成 Cloudflare Access 的浏览器登录，请使用兼容的访问策略。
API Token 只在配置过程中临时使用；后台仅保存运行所需的 Tunnel Token。
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
    local domain port uuid path name protocol dns cf_help
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
    jq -n --arg domain "$domain" --argjson port "$port" --arg uuid "$uuid" --arg path "$path" \
        --arg name "$name" --arg protocol "$protocol" --arg dns "$dns" \
        '{domain:$domain, port:$port, uuid:$uuid, path:$path, name:$name, protocol:$protocol, dns:$dns}' \
        > "$TMP_WORK/settings.json"
    generate_server "$TMP_WORK/settings.json" "$TMP_WORK/server.json"
    generate_exports "$TMP_WORK"
    sing-box check -c "$TMP_WORK/server.json"
    if ! confirm '使用 API Token 自动创建/更新 Tunnel、DNS，并保存配置启动本节点'; then
        say '已取消，原配置和原服务保持原状。'; return
    fi
    cf_provision "$TMP_WORK"
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
    cp -- "$CURRENT/"{settings.json,server.json,node.txt,clash-meta.json,tunnel.token} "$TMP_WORK/"
    cf_provision "$TMP_WORK"
    activate_generation "$TMP_WORK"
    install_manager
    start_services
    say 'Cloudflare 配置和后台运行 Token 已更新，API Token 未保存。'
}
rollback() {
    [[ -L "$STATE/previous" && -d "$STATE/previous" ]] || die '没有上一份配置。'
    confirm '回退到上一份配置并重启节点' || return 0
    local previous current
    previous=$(readlink "$STATE/previous")
    current=$(readlink "$CURRENT")
    sing-box check -c "$STATE/previous/server.json"
    if [[ "$(old_setting provisioning || true)" == api ]] ||
        [[ "$(jq -r '.provisioning // empty' "$STATE/previous/settings.json")" == api ]]; then
        say '回退涉及 API 管理的配置，请重新输入 API Token，以同步远程回源及 DNS。'
        TMP_WORK=$(mktemp -d "$STATE/.stage.XXXXXXXX")
        cp -- "$STATE/previous/"{settings.json,server.json,node.txt,clash-meta.json,tunnel.token} "$TMP_WORK/"
        cf_provision "$TMP_WORK"
        activate_generation "$TMP_WORK"
        start_services
        show_node
        return
    fi
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
  9) 重配 Cloudflare    10) 启用开机启动
 11) 关闭开机启动        12) API Token 权限说明
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
        guide) require_tools; show_guide "$(old_setting domain || printf node.example.com)" "$(old_setting port || printf 8080)" ;;
        rollback) require_tools; lock_action; rollback ;;
        uninstall) require_tools; lock_action; uninstall_node ;;
        *) die '未知命令。使用 --help 查看用法。' ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
