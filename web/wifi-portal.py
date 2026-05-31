#!/usr/bin/env python3
"""
rpi-wifi-portal  —  Captive portal web UI for WiFi provisioning
Runs on port 80 (falls back to 8080 if 80 blocked by OS).
Includes a DNS server on port 53 that redirects all queries to AP_IP
so phones auto-pop the captive portal page.
"""

import http.server
import json
import os
import socket
import socketserver
import struct
import subprocess
import threading
import urllib.parse
from datetime import datetime

PORT     = 80
FALLBACK = 8080
AP_IP    = os.environ.get("AP_IP", "192.168.4.1")
HOSTNAME = socket.gethostname()
WIFI_MGR = "/usr/local/bin/wifi-manager"


# ─── Subprocess helper ────────────────────────────────────────────────────────
def run_cmd(cmd, timeout=20):
    # type: (list, int) -> tuple
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout.strip()
    except subprocess.TimeoutExpired:
        return 1, "timeout"
    except Exception as e:
        return 1, str(e)


def get_status():
    _, out = run_cmd([WIFI_MGR, "status"])
    d = {"state": "UNKNOWN", "ssid": "", "ip": "", "iface": "wlan0"}
    for line in out.splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            d[k.strip().lower()] = v.strip()
    return d


def scan_networks():
    _, out = run_cmd([WIFI_MGR, "scan-json"], timeout=25)
    try:
        networks = json.loads(out)
        seen = {}
        for n in networks:
            s = n.get("ssid", "").strip()
            if not s or s.startswith("\\x"):
                continue
            if s not in seen or n.get("signal", 0) > seen[s].get("signal", 0):
                seen[s] = n
        return sorted(seen.values(), key=lambda x: x.get("signal", 0), reverse=True)
    except Exception:
        return []


# ─── DNS captive portal redirect ─────────────────────────────────────────────
# systemd-resolved occupies 127.0.0.53:53. We use iptables to redirect
# DNS queries arriving on the AP interface (192.168.4.x) to our handler
# on a high port (5353), avoiding the conflict entirely.

DNS_PORT = 15353  # high port away from mDNS (5353); iptables redirects :53 → here

class DNSHandler(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        try:
            tid      = data[:2]
            question = data[12:]
            ip_bytes = bytes(int(x) for x in AP_IP.split("."))
            response = (
                tid +
                b"\x81\x80" +   # QR=response, RCODE=ok
                b"\x00\x01" +   # QDCOUNT=1
                b"\x00\x01" +   # ANCOUNT=1
                b"\x00\x00\x00\x00" +
                question +
                b"\xc0\x0c" +   # name = ptr to question
                b"\x00\x01" +   # TYPE A
                b"\x00\x01" +   # CLASS IN
                b"\x00\x00\x00\x1e" +  # TTL 30
                b"\x00\x04" +   # RDLENGTH 4
                ip_bytes
            )
            sock.sendto(response, self.client_address)
        except Exception:
            pass


def setup_iptables_dns_redirect():
    """Redirect DNS on AP interface to our high port, bypassing systemd-resolved."""
    import subprocess as sp
    iface = os.environ.get("IFACE", "wlan0")
    cmds = [
        # Flush any old rule first to avoid duplicates
        f"iptables -t nat -D PREROUTING -i {iface} -p udp --dport 53 -j REDIRECT --to-port {DNS_PORT} 2>/dev/null || true",
        f"iptables -t nat -D PREROUTING -i {iface} -p tcp --dport 53 -j REDIRECT --to-port {DNS_PORT} 2>/dev/null || true",
        # Add fresh rules
        f"iptables -t nat -A PREROUTING -i {iface} -p udp --dport 53 -j REDIRECT --to-port {DNS_PORT}",
        f"iptables -t nat -A PREROUTING -i {iface} -p tcp --dport 53 -j REDIRECT --to-port {DNS_PORT}",
    ]
    for cmd in cmds:
        try:
            sp.run(cmd, shell=True, capture_output=True)
        except Exception as e:
            portal_log(f"[portal] iptables warning: {e}")
    portal_log(f"[portal] iptables DNS redirect: {iface}:53 → localhost:{DNS_PORT}")


def start_dns_server():
    setup_iptables_dns_redirect()
    try:
        server = socketserver.UDPServer(("0.0.0.0", DNS_PORT), DNSHandler)
        portal_log(f"[portal] DNS captive server listening on port {DNS_PORT}")
        server.serve_forever()
    except OSError as e:
        portal_log(f"[portal] DNS server error on port {DNS_PORT}: {e}")


# ─── HTML template ────────────────────────────────────────────────────────────
HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{hostname} WiFi Setup</title>
<style>
:root{{--bg:#0f172a;--card:#1e293b;--border:#334155;--accent:#38bdf8;
      --accent2:#818cf8;--text:#f1f5f9;--muted:#94a3b8;
      --danger:#f87171;--success:#4ade80;--warn:#fbbf24}}
*{{box-sizing:border-box;margin:0;padding:0}}
body{{background:var(--bg);color:var(--text);font-family:'Segoe UI',system-ui,sans-serif;
     min-height:100vh;display:flex;justify-content:center;padding:1.25rem}}
.wrap{{width:100%;max-width:460px}}
.hdr{{text-align:center;padding:1.2rem 0 .8rem}}
.hdr h1{{font-size:1.3rem;font-weight:700;color:var(--accent)}}
.hdr p{{color:var(--muted);font-size:.82rem;margin-top:.2rem}}
.card{{background:var(--card);border:1px solid var(--border);border-radius:12px;
       padding:1.1rem;margin-bottom:.9rem}}
.card h2{{font-size:.78rem;text-transform:uppercase;letter-spacing:.08em;
          color:var(--muted);margin-bottom:.9rem}}
.grid{{display:grid;grid-template-columns:1fr 1fr;gap:.65rem}}
.stat{{background:var(--bg);border-radius:8px;padding:.65rem}}
.stat .lbl{{font-size:.68rem;color:var(--muted);text-transform:uppercase}}
.stat .val{{font-size:.88rem;font-weight:600;word-break:break-all;margin-top:.15rem}}
.badge{{display:inline-block;padding:.15rem .55rem;border-radius:20px;
        font-size:.72rem;font-weight:600}}
.s-CONNECTED{{background:#14532d;color:var(--success)}}
.s-HOTSPOT{{background:#1e3a5f;color:var(--accent)}}
.s-SCANNING,.s-RECONNECTING{{background:#451a03;color:var(--warn)}}
.s-DISCONNECTED,.s-STOPPED,.s-UNKNOWN{{background:#450a0a;color:var(--danger)}}
.nets{{list-style:none}}
.net{{display:flex;align-items:center;padding:.6rem .4rem;
      border-bottom:1px solid var(--border);cursor:pointer;
      border-radius:6px;transition:background .15s}}
.net:hover{{background:rgba(56,189,248,.08)}}
.net:last-child{{border-bottom:none}}
.net svg{{width:22px;height:18px;margin-right:.65rem;flex-shrink:0}}
.net-n{{flex:1;font-size:.88rem}}
.sec{{font-size:.68rem;color:var(--muted);background:var(--bg);
      padding:.12rem .35rem;border-radius:4px}}
.empty{{text-align:center;color:var(--muted);padding:.9rem;font-size:.83rem}}
label{{display:block;font-size:.78rem;color:var(--muted);margin-bottom:.28rem}}
input[type=text],input[type=password]{{width:100%;background:var(--bg);
  border:1px solid var(--border);color:var(--text);border-radius:8px;
  padding:.6rem .7rem;font-size:.88rem;margin-bottom:.75rem;outline:none;
  transition:border-color .2s}}
input:focus{{border-color:var(--accent)}}
.pw{{position:relative}}
.pw input{{padding-right:2.8rem}}
.eye{{position:absolute;right:.7rem;top:50%;transform:translateY(-50%);
      background:none;border:none;color:var(--muted);cursor:pointer;font-size:.72rem}}
.btn{{width:100%;padding:.7rem;border:none;border-radius:8px;
      font-size:.88rem;font-weight:600;cursor:pointer;transition:opacity .2s}}
.primary{{background:linear-gradient(135deg,var(--accent),var(--accent2));color:#0f172a}}
.primary:hover{{opacity:.9}}
.secondary{{background:var(--border);color:var(--text);margin-top:.45rem}}
.alert{{padding:.6rem .85rem;border-radius:8px;font-size:.83rem;margin-bottom:.8rem}}
.a-ok{{background:#14532d;color:var(--success);border:1px solid #166534}}
.a-err{{background:#450a0a;color:var(--danger);border:1px solid #7f1d1d}}
.a-info{{background:#1e3a5f;color:var(--accent);border:1px solid #1e40af}}
.spin{{display:inline-block;width:13px;height:13px;border:2px solid rgba(56,189,248,.3);
       border-top-color:var(--accent);border-radius:50%;
       animation:sp .7s linear infinite;vertical-align:middle;margin-right:.35rem}}
@keyframes sp{{to{{transform:rotate(360deg)}}}}
.rescan{{font-size:.75rem;color:var(--accent);background:none;border:none;
         cursor:pointer;float:right;text-decoration:underline}}
.foot{{text-align:center;color:var(--muted);font-size:.72rem;padding:.4rem 0 1rem}}
</style>
</head>
<body><div class="wrap">
<div class="hdr"><h1>📡 {hostname}</h1><p>WiFi Setup Portal</p></div>

<div class="card">
  <h2>Status</h2>
  <div class="grid">
    <div class="stat"><div class="lbl">State</div>
      <div class="val"><span class="badge s-{state_cls}">{state}</span></div></div>
    <div class="stat"><div class="lbl">Connected SSID</div>
      <div class="val">{ssid}</div></div>
    <div class="stat"><div class="lbl">IP Address</div>
      <div class="val">{ip}</div></div>
    <div class="stat"><div class="lbl">Hotspot SSID</div>
      <div class="val">{ap_ssid}</div></div>
  </div>
</div>

{alert}

<div class="card" id="ncard">
  <h2>Networks <button class="rescan" onclick="rescan()">↻ Rescan</button></h2>
  {netlist}
</div>

<div class="card">
  <h2>Connect</h2>
  <form id="wf" method="POST" action="/connect">
    <label>Network (SSID)</label>
    <input type="text" name="ssid" id="ssid" value="{prefill}"
           placeholder="Select above or type SSID" required autocomplete="off" autocapitalize="none">
    <label>Password</label>
    <div class="pw">
      <input type="password" name="password" id="pw" placeholder="Leave blank for open networks">
      <button type="button" class="eye" onclick="togglepw()">SHOW</button>
    </div>
    <button class="btn primary" id="cb">Connect</button>
  </form>
  <form method="POST" action="/hotspot">
    <button class="btn secondary">Start Hotspot Only</button>
  </form>
</div>
<div class="foot">{hostname} · <a href="http://{hostname}.local" style="color:var(--accent);text-decoration:none">{hostname}.local</a> · {ts}</div>
</div>
<script>
function fillSsid(n){{document.getElementById('ssid').value=n;
  document.getElementById('pw').focus();}}
function togglepw(){{var p=document.getElementById('pw'),b=document.querySelector('.eye');
  p.type=p.type==='password'?'text':'password';b.textContent=p.type==='password'?'SHOW':'HIDE';}}
function bars(s){{var c=function(a){{return a?'#38bdf8':'#334155';}};
  return '<svg viewBox="0 0 22 18"><rect x="0" y="13" width="4" height="5" fill="'+c(s>10)+'"/>'
    +'<rect x="5" y="9" width="4" height="9" fill="'+c(s>30)+'"/>'
    +'<rect x="10" y="4" width="4" height="14" fill="'+c(s>55)+'"/>'
    +'<rect x="15" y="0" width="4" height="18" fill="'+c(s>75)+'"/></svg>';}}
function esc(s){{return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');}}
function rescan(){{
  var c=document.getElementById('ncard');
  c.innerHTML='<h2>Networks <button class="rescan" onclick="rescan()">↻ Rescan</button></h2>'
    +'<div class="empty"><span class="spin"></span>Scanning…</div>';
  fetch('/scan-json').then(function(r){{return r.json();}}).then(function(nets){{
    var h='<h2>Networks <button class="rescan" onclick="rescan()">↻ Rescan</button></h2>';
    if(!nets.length){{h+='<div class="empty">No networks found.</div>';}}
    else{{h+='<ul class="nets">';
      nets.forEach(function(n){{
        var sec=n.security&&n.security!=='OPEN'?'<span class="sec">'+esc(n.security)+'</span>':'';
        h+='<li class="net" onclick="fillSsid(\''+esc(n.ssid)+'\')">'
          +bars(n.signal)+'<span class="net-n">'+esc(n.ssid)+'</span>'+sec+'</li>';
      }});h+='</ul>';}}
    c.innerHTML=h;
  }}).catch(function(){{c.innerHTML+='<div class="alert a-err">Scan failed</div>';}});
}}
document.getElementById('wf').addEventListener('submit',function(){{
  var b=document.getElementById('cb');
  b.innerHTML='<span class="spin"></span>Connecting…';b.disabled=true;}});
{autoreload}
</script></body></html>"""


def signal_bars(sig):
    c = lambda a: "#38bdf8" if a else "#334155"
    return (
        f'<svg viewBox="0 0 22 18">'
        f'<rect x="0" y="13" width="4" height="5"  fill="{c(sig>10)}"/>'
        f'<rect x="5" y="9"  width="4" height="9"  fill="{c(sig>30)}"/>'
        f'<rect x="10" y="4" width="4" height="14" fill="{c(sig>55)}"/>'
        f'<rect x="15" y="0" width="4" height="18" fill="{c(sig>75)}"/>'
        f'</svg>'
    )


def render_netlist(networks):
    if not networks:
        return '<div class="empty">No networks found — click Rescan.</div>'
    html = '<ul class="nets">'
    for n in networks:
        ssid = n.get("ssid", "").replace('"', "&quot;").replace("<", "&lt;")
        sig  = n.get("signal", 0)
        sec  = n.get("security", "OPEN")
        sec_badge = f'<span class="sec">{sec}</span>' if sec and sec != "OPEN" else ""
        html += (
            f'<li class="net" onclick="fillSsid(\'{ssid}\')">'
            f'{signal_bars(sig)}<span class="net-n">{ssid}</span>{sec_badge}</li>'
        )
    return html + "</ul>"


# Shared scan cache
_cache      = []
_cache_lock = threading.Lock()
_cache_time = 0.0

# Global operation lock — prevents portal connect and watchdog reconnect racing
_op_lock = threading.Lock()


def cached_scan(force=False):
    """Return cached results immediately. Trigger background rescan if stale."""
    import time
    global _cache, _cache_time
    with _cache_lock:
        current = list(_cache)
        needs_scan = force or (time.time() - _cache_time > 30)

    if needs_scan:
        # Always run scan in background — never block the HTTP server
        def _bg_scan():
            global _cache, _cache_time
            results = scan_networks()
            with _cache_lock:
                _cache = results
                _cache_time = time.time()
        threading.Thread(target=_bg_scan, daemon=True).start()

    return current


def render_page(alert="", prefill="", connecting=False):
    status  = get_status()
    nets    = cached_scan()
    ap_ssid = os.environ.get("AP_SSID", f"RPI-{HOSTNAME}-Setup")
    state   = status.get("state", "UNKNOWN")
    cls     = state.split("[")[0]

    if connecting:
        # Poll /status every 3s and update the alert div in-place.
        # Works even after hotspot drops because fetch retries on network error.
        autoreload = (
            "(function poll(){"
            "setTimeout(function(){"
            "fetch('/status')"
            ".then(function(r){return r.json();})"
            ".then(function(s){"
            "var el=document.getElementById('conn-status');"
            "if(s.state==='CONNECTED'){"
            "if(el){el.innerHTML='&#10003; Connected to <b>'+s.ssid+'</b> &nbsp;IP: '+s.ip;"
            "el.className='alert a-ok';}"
            "}else if(s.state==='HOTSPOT'||s.state==='DISCONNECTED'){"
            "if(el){el.innerHTML='&#10007; Failed &mdash; wrong password? Hotspot restarted.';"
            "el.className='alert a-err';}"
            "}else{poll();}"
            "}).catch(function(){poll();});"
            "},3000);"
            "})();"
        )
    else:
        autoreload = (
            "setTimeout(function(){location.reload();},6000);"
            if any(state.startswith(s) for s in ["CONNECT", "SCAN", "RECONNECT"])
            else ""
        )
    return HTML.format(
        hostname   = HOSTNAME,
        state      = state,
        state_cls  = cls,
        ssid       = status.get("ssid", "—"),
        ip         = status.get("ip", "—"),
        ap_ssid    = ap_ssid,
        netlist    = render_netlist(nets),
        alert      = alert,
        prefill    = prefill,
        ts         = datetime.now().strftime("%H:%M:%S"),
        autoreload = autoreload,
    )


class PortalHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # journald handles logging

    def send_html(self, body, code=200):
        enc = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(enc)))
        # Captive portal detection headers
        self.send_header("Cache-Control", "no-cache, no-store")
        self.end_headers()
        self.wfile.write(enc)

    def send_json(self, data, code=200):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def redirect(self, loc):
        self.send_response(302)
        self.send_header("Location", loc)
        self.end_headers()

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/scan-json":
            # Return current cache immediately, background scan already triggered
            cached_scan(force=True)   # triggers bg rescan, returns stale data
            import time; time.sleep(0.1)  # tiny yield for bg thread to start
            self.send_json(cached_scan())  # return whatever we have now
        elif path == "/status":
            self.send_json(get_status())
        elif path in ("/", "/index.html"):
            self.send_html(render_page())
        else:
            # Captive portal probes from Android/iOS/Windows — all redirect home
            self.redirect(f"http://{AP_IP}/")

    def do_POST(self):
        length  = int(self.headers.get("Content-Length", 0))
        raw     = self.rfile.read(length).decode(errors="replace")
        params  = urllib.parse.parse_qs(raw)

        if self.path == "/connect":
            ssid = params.get("ssid", [""])[0].strip()
            pwd  = params.get("password", [""])[0]
            if not ssid:
                self.send_html(render_page(
                    '<div class="alert a-err">SSID cannot be empty.</div>'
                ))
                return

            # Return the "connecting" page IMMEDIATELY so the browser gets a
            # response before the hotspot drops (hotspot drops ~1s after connect starts)
            # The page auto-polls /status every 3s to detect success or failure
            self.send_html(render_page(
                f'<div class="alert a-info" id="conn-status">'
                f'<span class="spin"></span>Connecting to <b>{ssid}</b>…</div>',
                prefill=ssid,
                connecting=True,
            ))

            # Fire connect in background AFTER response is sent
            def _connect():
                with _op_lock:
                    cmd = [WIFI_MGR, "connect", ssid]
                    if pwd:
                        cmd.append(pwd)
                    run_cmd(cmd, timeout=45)
            threading.Thread(target=_connect, daemon=True).start()

        elif self.path == "/hotspot":
            threading.Thread(
                target=lambda: run_cmd([WIFI_MGR, "hotspot"], timeout=20),
                daemon=True,
            ).start()
            self.send_html(render_page(
                '<div class="alert a-info">Starting hotspot…</div>'
            ))
        else:
            self.redirect("/")


def portal_log(msg):
    import sys
    print(msg, flush=True)


def main():
    import sys
    portal_log("[portal] Starting rpi-wifi-portal...")

    # Background DNS for captive portal auto-detection
    threading.Thread(target=start_dns_server, daemon=True).start()

    # Background initial scan so first page load is fast
    threading.Thread(target=lambda: cached_scan(force=True), daemon=True).start()

    server = None
    bound_port = None
    for attempt_port in (PORT, FALLBACK):
        try:
            server = http.server.ThreadingHTTPServer(("0.0.0.0", attempt_port), PortalHandler)
            bound_port = attempt_port
            portal_log(f"[portal] Bound successfully to port {bound_port}")
            break
        except PermissionError:
            portal_log(f"[portal] Port {attempt_port} permission denied, trying {FALLBACK}...")
        except OSError as e:
            portal_log(f"[portal] Port {attempt_port} OSError: {e}, trying next...")

    if server is None:
        portal_log("[portal] FATAL: Could not bind to port 80 or 8080. Exiting.")
        sys.exit(1)

    if bound_port == 80:
        portal_log(f"[portal] Visit: http://{AP_IP}/")
    else:
        portal_log(f"[portal] Visit: http://{AP_IP}:{bound_port}/")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        portal_log("[portal] Shutting down.")


if __name__ == "__main__":
    main()
