#!/usr/bin/env python3
"""Exercise the real interactive Bash installer against a private TLS Cloudflare API fixture.

SB_BIN=/absolute/path/to/sing-box python3 tests/api-smoke.py
No Cloudflare credentials, external API writes, packages, or production services are used.
"""
import base64
import http.server
import json
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import tempfile
import threading
import unittest
from urllib.parse import parse_qs, urlsplit
import uuid

REPO = Path(__file__).resolve().parent.parent
API_TOKEN = "fixture-api-token-not-a-real-credential-123456"
ACCOUNT = "a" * 32
ZONE = "b" * 32


def connector_token(tunnel):
    return base64.b64encode(json.dumps({"a": ACCOUNT, "t": tunnel, "s": "fixture-secret"}).encode()).decode()


class APIHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def reply(self, result=None, status=200, message="fixture error"):
        body = json.dumps({"success": status < 300, "result": result,
                           "errors": [] if status < 300 else [{"code": 10000, "message": message}]}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_api(self):
        state = self.server.state
        url = urlsplit(self.path)
        path = url.path.removeprefix("/client/v4")
        query = parse_qs(url.query)
        data = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        state["calls"].append((self.command, path, data))
        if self.headers.get("Authorization") != "Bearer " + API_TOKEN or state.get("deny"):
            self.reply(status=403, message="Authentication error")
            return
        if state.get("bad_json"):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"<html>not an API response</html>")
            return
        if path == "/zones":
            name = query.get("name", [""])[0]
            zones = {"example.com": ZONE, **state.get("extra_zones", {})}
            result = ([{"id": zones[name], "name": name, "status": "active", "account": {"id": ACCOUNT}}]
                      if name in zones else [])
            self.reply(result)
            return
        tunnel_prefix = f"/accounts/{ACCOUNT}/cfd_tunnel"
        if path == tunnel_prefix:
            if self.command == "GET":
                name = query.get("name", [""])[0]
                self.reply([t for t in state["tunnels"].values() if t["name"] == name])
            elif self.command == "POST":
                if data.get("config_src") != "cloudflare":
                    self.reply(status=400, message="config_src must be cloudflare")
                    return
                tunnel = str(uuid.uuid4())
                state["tunnels"][tunnel] = {"id": tunnel, "name": data["name"], "config_src": "cloudflare", "deleted_at": None}
                if state.pop("drop_create_reply_once", False):
                    self.close_connection = True  # POST succeeded, but the client never received its ID.
                    return
                self.reply(state["tunnels"][tunnel])
            else:
                self.reply(status=405)
            return
        if path.startswith(tunnel_prefix + "/"):
            parts = path[len(tunnel_prefix) + 1:].split("/")
            tunnel = parts[0]
            if tunnel not in state["tunnels"]:
                self.reply(status=404)
            elif len(parts) == 1:
                self.reply(state["tunnels"][tunnel])
            elif parts[1] == "token":
                self.reply(connector_token(tunnel))
            elif parts[1] == "configurations":
                if self.command == "GET":
                    if tunnel not in state["configs"]:
                        self.reply(status=404, message="No tunnel configuration found")
                    else:
                        self.reply({"config": state["configs"][tunnel]})
                else:
                    config = data.get("config", {})
                    ingress = config.get("ingress", [])
                    if not ingress or "hostname" in ingress[-1] or "path" in ingress[-1]:
                        self.reply(status=400, message="Missing final catch-all rule")
                    else:
                        state["configs"][tunnel] = config
                        self.reply({"config": config})
            else:
                self.reply(status=404)
            return
        dns_prefix = f"/zones/{state.get('active_zone', ZONE)}/dns_records"
        if path == dns_prefix and self.command == "GET":
            name = query.get("name", [""])[0]
            self.reply([r for r in state["dns"].values() if r["name"] == name])
            return
        if path == dns_prefix or path.startswith(dns_prefix + "/"):
            if state.get("deny_dns_write"):
                self.reply(status=403, message="DNS write permission denied")
                return
            if self.command == "POST":
                if any(r["name"] == data["name"] for r in state["dns"].values()):
                    self.reply(status=409)
                    return
                record_id = uuid.uuid4().hex
                state["dns"][record_id] = {"id": record_id, **data}
                self.reply(state["dns"][record_id])
            elif self.command == "PATCH":
                record_id = path.rsplit("/", 1)[1]
                if record_id not in state["dns"]:
                    self.reply(status=404)
                else:
                    state["dns"][record_id].update(data)
                    self.reply(state["dns"][record_id])
            else:
                self.reply(status=405)
            return
        self.reply(status=404, message="Unimplemented fixture route: " + path)

    do_GET = do_POST = do_PATCH = do_PUT = handle_api


class APIIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tools = tempfile.TemporaryDirectory(prefix="tcf-api-tools-")
        cls.tool_root = Path(cls.tools.name)
        cls.sb = os.environ.get("SB_BIN") or shutil.which("sing-box")
        if not cls.sb:
            raise unittest.SkipTest("Set SB_BIN to a real sing-box binary")
        cls.real_curl = shutil.which("curl")
        cert = cls.tool_root / "cert.pem"
        key = cls.tool_root / "key.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-subj", "/CN=localhost", "-addext", "subjectAltName=IP:127.0.0.1",
                        "-keyout", str(key), "-out", str(cert)], check=True, capture_output=True)
        cls.cert = cert
        cls.key = key

    @classmethod
    def tearDownClass(cls):
        cls.tools.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="tcf-api-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home with space"
        self.prefix = self.root / "prefix"
        self.bin = self.prefix / "bin"
        self.bin.mkdir(parents=True)
        self.home.mkdir()
        self.state = {"tunnels": {}, "configs": {}, "dns": {}, "calls": []}
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), APIHandler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(self.cert, self.key)
        self.server.socket = context.wrap_socket(self.server.socket, server_side=True)
        self.server.state = self.state
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        # Only rewrite the API hostname. The production curl options, TLS, HTTP, headers,
        # request bodies and response parser are all exercised by the real curl binary.
        curl_wrapper = f"""#!/usr/bin/python3
import json, os, sys
args=sys.argv[1:]
with open({str(self.root / 'curl-argv.jsonl')!r}, 'a') as f: f.write(json.dumps(args)+'\\n')
prefix='https://api.cloudflare.com/client/v4'
args=[a.replace(prefix, 'https://127.0.0.1:{self.server.server_port}/client/v4', 1) if a.startswith(prefix) else a for a in args]
args.extend(['--cacert', {str(self.cert)!r}])
os.execv({self.real_curl!r}, [{self.real_curl!r}]+args)
"""
        (self.bin / "curl").write_text(curl_wrapper)
        (self.bin / "curl").chmod(0o700)
        for name in ["bash", "jq", "flock"]:
            (self.bin / name).symlink_to(shutil.which(name))
        (self.bin / "sing-box").symlink_to(self.sb)
        (self.bin / "cloudflared").write_text("#!/bin/sh\nprintf '%s\\n' '--token-file --dns-resolver-addrs'\n")
        (self.bin / "cloudflared").chmod(0o700)
        (self.bin / "sv").write_text("#!/bin/sh\nexit 0\n")
        (self.bin / "sv").chmod(0o700)
        self.project_state = self.home / ".local/share/termux-cf-node"
        self.env = {**os.environ, "HOME": str(self.home), "PREFIX": str(self.prefix),
                    "PATH": str(self.bin) + ":" + os.environ["PATH"]}
        self.harness = self.root / "harness.sh"
        self.harness.write_text(f"""#!/bin/bash
source {str(REPO / 'termux-cf-node.sh')!r}
trap cleanup EXIT
# Platform effects are stubbed; the interactive installer and all API work are real.
pkg() {{ :; }}
start_services() {{ printf 'runtime start stub\\n'; }}
case "$1" in
 install) configure ;;
 token) lock_action; change_token ;;
 rollback) lock_action; rollback ;;
esac
""")

    def run_action(self, action="install", *, domain="node.example.com", port="", key=API_TOKEN, success=True):
        if action == "install":
            answers = [domain, port, "", "", "", "", "", "y", key, "n"]
        elif action == "rollback":
            answers = ["y", key]
        else:
            answers = [key]
        p = subprocess.run(["bash", str(self.harness), action], input="\n".join(answers) + "\n",
                           capture_output=True, text=True, env=self.env, timeout=40)
        output = p.stdout + p.stderr
        self.assertNotIn(API_TOKEN, output)
        if success:
            self.assertEqual(p.returncode, 0, output)
        else:
            self.assertNotEqual(p.returncode, 0, output)
        return output

    def active_settings(self):
        return json.loads((self.project_state / "current/settings.json").read_text())

    def assert_no_api_credentials(self):
        for path in self.project_state.rglob("*"):
            if path.is_file():
                self.assertNotIn(API_TOKEN.encode(), path.read_bytes(), str(path))
        args = (self.root / "curl-argv.jsonl").read_text()
        self.assertNotIn(API_TOKEN, args)
        self.assertIn("--header", args)
        self.assertNotIn("--insecure", args)

    def test_create_idempotent_update_and_remote_rollback(self):
        self.run_action()
        tunnel = next(iter(self.state["tunnels"]))
        first_name = self.state["tunnels"][tunnel]["name"]
        self.assertTrue(first_name.startswith("tcf-node-"))
        record = next(iter(self.state["dns"].values()))
        self.assertEqual(record["content"], tunnel + ".cfargotunnel.com")
        self.assertTrue(record["proxied"])
        self.assertEqual(self.active_settings()["provisioning"], "api")
        # Updating this hostname must preserve other Tunnel applications and global settings.
        extra_rule = {"hostname": "other.example.com", "service": "http://127.0.0.1:9000"}
        self.state["configs"][tunnel]["ingress"].insert(0, extra_rule)
        self.state["configs"][tunnel]["warp-routing"] = {"enabled": True}
        self.run_action(port="9090")
        self.assertEqual(len(self.state["tunnels"]), 1)
        self.assertEqual(len(self.state["dns"]), 1)
        self.assertEqual(self.state["configs"][tunnel]["ingress"][0], extra_rule)
        self.assertEqual(self.state["configs"][tunnel]["warp-routing"], {"enabled": True})
        self.run_action("rollback")
        self.assertEqual(self.active_settings()["port"], 8080)
        self.assertEqual(self.state["configs"][tunnel]["ingress"][-2]["service"], "http://127.0.0.1:8080")
        self.run_action("token")
        self.assertEqual(len(self.state["tunnels"]), 1)
        self.assert_no_api_credentials()

    def test_dns_conflict_has_no_remote_writes(self):
        record = {"id": "c" * 32, "type": "A", "name": "node.example.com", "content": "192.0.2.1"}
        self.state["dns"][record["id"]] = record.copy()
        output = self.run_action(success=False)
        self.assertIn("DNS 冲突", output)
        self.assertEqual(self.state["tunnels"], {})
        self.assertEqual(self.state["dns"][record["id"]], record)
        self.assertFalse(any(method != "GET" for method, _, _ in self.state["calls"]))
        self.assert_no_api_credentials()

    def test_denied_permission_and_invalid_api_response(self):
        self.state["deny"] = True
        output = self.run_action(success=False)
        self.assertIn("HTTP 403", output)
        self.state["deny"] = False
        self.state["bad_json"] = True
        self.run_action(success=False)
        self.assertEqual(self.state["tunnels"], {})
        self.assert_no_api_credentials()

    def test_timed_out_create_is_reused_on_retry(self):
        self.state["drop_create_reply_once"] = True
        self.run_action(success=False)
        self.assertEqual(len(self.state["tunnels"]), 1)
        self.run_action()
        self.assertEqual(len(self.state["tunnels"]), 1)
        creates = [c for c in self.state["calls"] if c[0] == "POST" and c[1].endswith("/cfd_tunnel")]
        self.assertEqual(len(creates), 1)
        self.assert_no_api_credentials()

    def test_dns_write_failure_restores_previous_remote_config(self):
        self.run_action()
        tunnel = next(iter(self.state["tunnels"]))
        original = json.loads(json.dumps(self.state["configs"][tunnel]))
        self.state["deny_dns_write"] = True
        output = self.run_action(port="9090", success=False)
        self.assertIn("已恢复修改前", output)
        self.assertEqual(self.state["configs"][tunnel], original)
        self.assertEqual(self.active_settings()["port"], 8080)
        self.assert_no_api_credentials()

    def test_migration_of_existing_connector_preserves_other_apps(self):
        self.run_action()
        tunnel = next(iter(self.state["tunnels"]))
        settings = self.active_settings()
        settings.pop("provisioning")  # Pre-1.1 local configuration with a Tunnel Token.
        (self.project_state / "current/settings.json").write_text(json.dumps(settings))
        (self.project_state / "current/cloudflare.json").unlink()
        extra_rule = {"hostname": "existing.example.com", "service": "http://127.0.0.1:8000"}
        self.state["configs"][tunnel]["ingress"].insert(0, extra_rule)
        self.run_action()
        self.assertEqual(len(self.state["tunnels"]), 1)
        self.assertEqual(self.state["configs"][tunnel]["ingress"][0], extra_rule)
        self.assertEqual(self.active_settings()["provisioning"], "api")

    def test_most_specific_subzone(self):
        subzone = "d" * 32
        self.state["extra_zones"] = {"sub.example.com": subzone}
        self.state["active_zone"] = subzone
        self.run_action(domain="node.sub.example.com")
        metadata = json.loads((self.project_state / "current/cloudflare.json").read_text())
        self.assertEqual(metadata["zone_id"], subzone)


if __name__ == "__main__":
    unittest.main(verbosity=2)
