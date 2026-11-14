#!/usr/bin/env bash
# Host integration check. No Android or Cloudflare credentials required.
# SB_BIN=/path/to/sing-box RUNIT_BIN=/path/to/runit/usr/bin bash tests/smoke.sh
# Requires bash, jq, curl, python3, coreutils, util-linux and real runit binaries.
set -Eeuo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
: "${SB_BIN:?Set SB_BIN to a real sing-box binary}"
: "${RUNIT_BIN:?Set RUNIT_BIN to the directory containing sv, runsvdir, runsv and svlogd}"
TEST_ROOT=$(mktemp -d)
export HOME="$TEST_ROOT/home with space" PREFIX="$TEST_ROOT/prefix"
mkdir -p "$HOME" "$PREFIX/bin" "$PREFIX/var/service"
export PATH="$PREFIX/bin:$PATH"
SERVER_PID=''

for tool in bash jq curl flock; do ln -s "$(command -v "$tool")" "$PREFIX/bin/$tool"; done
ln -s "$SB_BIN" "$PREFIX/bin/sing-box"
for tool in sv runsv runsvdir svlogd; do ln -s "$RUNIT_BIN/$tool" "$PREFIX/bin/$tool"; done

# Source exposes the production functions without bypassing its Android-only CLI check.
# shellcheck source-path=SCRIPTDIR source=../termux-cf-node.sh
source "$REPO/termux-cf-node.sh"

cleanup_test() {
    local result=$?
    trap - EXIT ERR
    for service in "$SV_CF" "$SV_SB"; do
        [[ ! -p "$service/supervise/control" ]] || sv -w 5 down "$service" >/dev/null 2>&1 || true
        [[ ! -p "$service/supervise/control" ]] || sv -w 5 exit "$service" >/dev/null 2>&1 || true
    done
    if [[ -f "$PREFIX/daemon.pid" ]]; then
        kill "$(cat "$PREFIX/daemon.pid")" 2>/dev/null || true
    fi
    [[ -z "$SERVER_PID" ]] || kill "$SERVER_PID" 2>/dev/null || true
    cleanup
    rm -rf -- "$TEST_ROOT"
    exit "$result"
}
trap cleanup_test EXIT

expect_bad() { if "$@"; then printf 'Unexpected acceptance: %s\n' "$*" >&2; exit 1; fi; }
valid_domain node.example.com
valid_domain xn--fiqs8s.example
for value in 'https://x.com' 'a..com' '-a.com' 'a-.com' 'a.com:443' 'a.com/' 'a.com.' '.a.com'; do expect_bad valid_domain "$value"; done
valid_port 8080
valid_port 01024
for value in 0 1023 65536 999999 abc '8080;id'; do expect_bad valid_port "$value"; done
valid_path /abc/def_123-456
for value in / 'abc' '/a?x=1' '/a#b' '/a b'; do expect_bad valid_path "$value"; done
for value in 1.1.1.1 0.0.0.0 255.255.255.255 ::1 :: 2606:4700:4700::1111 2001:db8:1:2:3:4:5:6; do valid_dns "$value"; done
for value in 1.1.1 256.1.1.1 1.1.1.1.1 ::: 1::2::3 2001:db8:1:2:3:4:5 2001:db8:1:2:3:4:5:6:7 z::1; do expect_bad valid_dns "$value"; done
answer=''
ask answer 'prompt' default-value <<< ''
[[ "$answer" == default-value ]]
confirm 'confirmation' <<< y
expect_bad confirm 'confirmation' <<< n
say 'PASS input validation, default handling and confirmation'

mkdir -p "$STATE"
TMP_WORK=$(mktemp -d "$STATE/.stage.XXXXXXXX")
uuid=11111111-1111-4111-8111-111111111111
local_port=$(python3 - <<'PY'
import socket
with socket.socket() as s:
    s.bind(('127.0.0.1', 0))
    print(s.getsockname()[1])
PY
)
jq -n --arg uuid "$uuid" --argjson port "$local_port" \
    '{domain:"node.example.com",port:$port,uuid:$uuid,path:"/test-path",name:"手机 测试 #1",protocol:"auto",dns:"1.1.1.1"}' > "$TMP_WORK/settings.json"
jq -nc '{a:"00000000000000000000000000000000",t:"11111111-1111-4111-8111-111111111111",s:"test-only-not-a-real-token"}|@base64' | jq -r . > "$TMP_WORK/tunnel.token"
valid_token "$(cat "$TMP_WORK/tunnel.token")"
expect_bad valid_token garbage
# Keep shell metacharacters literal: they are adversarial input, not executable code.
# shellcheck disable=SC2016
expect_bad valid_token '$(touch /tmp/should-not-run)'
generate_server "$TMP_WORK/settings.json" "$TMP_WORK/server.json"
generate_exports "$TMP_WORK"
sing-box check -c "$TMP_WORK/server.json"
python3 - "$TMP_WORK/node.txt" <<'PY'
from urllib.parse import urlsplit, parse_qs, unquote
from pathlib import Path
import sys
u=urlsplit(Path(sys.argv[1]).read_text().strip())
assert u.scheme == 'vless' and u.hostname == 'node.example.com' and u.port == 443
q=parse_qs(u.query)
assert q['path'] == ['/test-path'] and q['security'] == ['tls'] and q['type'] == ['ws']
assert unquote(u.fragment) == '手机 测试 #1'
PY
activate_generation "$TMP_WORK"
[[ $(stat -c %a "$CURRENT/tunnel.token") == 600 ]]
[[ $(stat -c %a "$STATE") == 700 ]]
say 'PASS real sing-box server schema, URI encoding, private credentials and atomic activation'

# Emulate only Termux's platform launcher. The actual supervisors and proxy core are real.
cat > "$PREFIX/bin/service-daemon" <<'SH'
#!/bin/bash
set -eu
if [[ -f "$PREFIX/daemon.pid" ]] && kill -0 "$(cat "$PREFIX/daemon.pid")" 2>/dev/null; then exit 0; fi
nohup "$PREFIX/bin/runsvdir" "$PREFIX/var/service" > "$PREFIX/daemon.log" 2>&1 < /dev/null &
printf '%s\n' "$!" > "$PREFIX/daemon.pid"
SH
cat > "$PREFIX/bin/cloudflared" <<'SH'
#!/bin/bash
# This test does not create any external tunnel or pretend to verify Cloudflare connectivity.
set -eu
printf '%s\0' "$@" > "$PREFIX/cloudflared.args"
printf 'cloudflared test connector, no external connection\n'
exec /bin/sleep 600
SH
chmod 700 "$PREFIX/bin/service-daemon" "$PREFIX/bin/cloudflared"
write_services
for service in "$SV_SB" "$SV_CF"; do
    bash -n "$service/run"
    bash -n "$service/log/run"
done

# Private HTTP destination proves that proxy bytes actually pass through the VLESS server.
python3 - "$TEST_ROOT/http.port" <<'PY' &
import http.server
from pathlib import Path
import sys
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body=b'phone-egress-ok'
        self.send_response(200)
        self.send_header('Content-Length',str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self,*args): pass
server=http.server.HTTPServer(('127.0.0.1',0),Handler)
Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
PY
SERVER_PID=$!
for ((i=0;i<30;i++)); do [[ ! -f "$TEST_ROOT/http.port" ]] || break; sleep 0.1; done
target="http://127.0.0.1:$(cat "$TEST_ROOT/http.port")/"
start_services
sv status "$SV_SB" "$SV_CF"
[[ -s "$PREFIX/cloudflared.args" ]]
python3 - "$PREFIX/cloudflared.args" "$CURRENT/tunnel.token" <<'PY'
from pathlib import Path
import sys
args=Path(sys.argv[1]).read_bytes().split(b'\0')
assert b'--token-file' in args and b'--token' not in args
assert Path(sys.argv[2]).read_bytes().strip() not in args
assert b'127.0.0.1:0' in args
assert args[args.index(b'--dns-resolver-addrs')+1] == b'1.1.1.1:53'
config=Path(args[args.index(b'--config')+1].decode())
assert config.read_text().strip() == '{}'
PY
say 'PASS real runit supervision and token-file invocation (Cloudflare connector stubbed)'

TMP_WORK=$(mktemp -d "$STATE/.probe.XXXXXXXX")
probe_request() {
    local settings=$1 expected=$2 probe_port
    probe_port=$(shuf -i 20000-60000 -n 1)
    generate_probe "$settings" "$TMP_WORK/client.json" "$probe_port" local
    sing-box check -c "$TMP_WORK/client.json"
    sing-box run -c "$TMP_WORK/client.json" > "$TMP_WORK/client.log" 2>&1 &
    PROBE_PID=$!
    sleep 0.5
    local result
    if result=$(curl --silent --show-error --fail --proxy "socks5h://127.0.0.1:$probe_port" --noproxy '' --max-time 4 "$target" 2>"$TMP_WORK/curl.log"); then
        [[ "$expected" == pass && "$result" == phone-egress-ok ]]
    else
        [[ "$expected" == fail ]]
    fi
    kill "$PROBE_PID"
    wait "$PROBE_PID" 2>/dev/null || true
    PROBE_PID=''
}
probe_request "$CURRENT/settings.json" pass
jq '.uuid="22222222-2222-4222-8222-222222222222"' "$CURRENT/settings.json" > "$TMP_WORK/bad-uuid.json"
probe_request "$TMP_WORK/bad-uuid.json" fail
jq '.path="/wrong-path"' "$CURRENT/settings.json" > "$TMP_WORK/bad-path.json"
probe_request "$TMP_WORK/bad-path.json" fail
generate_probe "$CURRENT/settings.json" "$TMP_WORK/public.json" 19999 public
sing-box check -c "$TMP_WORK/public.json"
say 'PASS authenticated VLESS/WS bytes, wrong UUID rejection, wrong path rejection and WSS client schema'

old_pid=$(cat "$SV_SB/supervise/pid")
kill "$old_pid"
for ((i=0;i<60;i++)); do
    new_pid=$(cat "$SV_SB/supervise/pid")
    if [[ "$new_pid" != 0 && "$new_pid" != "$old_pid" ]]; then break; fi
    sleep 0.1
done
[[ "$new_pid" != 0 && "$new_pid" != "$old_pid" ]]
probe_request "$CURRENT/settings.json" pass
stop_services
sleep 2
[[ $(sv status "$SV_SB") == down:* && -f "$SV_SB/down" ]]
[[ $(sv status "$SV_CF") == down:* && -f "$SV_CF/down" ]]
say 'PASS actual crash restart and persistent stop without killing unrelated processes'

rm -rf "$TMP_WORK"
TMP_WORK=$(mktemp -d "$STATE/.stage.XXXXXXXX")
cp "$CURRENT/"{settings.json,server.json,node.txt,clash-meta.json,tunnel.token} "$TMP_WORK/"
old_target=$(readlink "$CURRENT")
activate_generation "$TMP_WORK"
[[ $(readlink "$STATE/previous") == "$old_target" ]]
[[ $(find "$STATE/releases" -mindepth 1 -maxdepth 1 -type d | wc -l) == 2 ]]
TMP_WORK=$(mktemp -d "$STATE/.stage.XXXXXXXX")
cp "$CURRENT/"{settings.json,server.json,node.txt,clash-meta.json,tunnel.token} "$TMP_WORK/"
second_target=$(readlink "$CURRENT")
activate_generation "$TMP_WORK"
[[ $(readlink "$STATE/previous") == "$second_target" ]]
[[ ! -d "$STATE/$old_target" ]]
[[ $(find "$STATE/releases" -mindepth 1 -maxdepth 1 -type d | wc -l) == 2 ]]
rollback <<< y
[[ $(readlink "$CURRENT") == "$second_target" ]]
stop_services
install_manager
enable_boot
bash -n "$BOOT"
bash -n "$PREFIX/bin/tcf-node"
say 'PASS previous configuration retention and generated manager / boot script syntax'
say 'ALL HOST INTEGRATION CHECKS PASSED. Real Android / Cloudflare acceptance remains device-side.'
