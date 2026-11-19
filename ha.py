#!/usr/bin/env python3
"""Home Assistant helper for the Omarchy shell plugin.

Standard library only. Every command prints JSON on stdout; `watch` prints one
JSON object per line until it is killed.

  discover                      find Home Assistant servers over mDNS
  servers                       servers that have stored credentials
  login <uuid> <url> [name]     OAuth login through the browser (no long-lived token)
  logout <uuid>                 forget stored credentials
  suggest <uuid>                favorites, common controls, dashboard + all entities
  watch <uuid> <entity_id>...   stream state for the given entities
  toggle <uuid> <entity_id>     toggle / press / run an entity
  action <uuid> <entity_id> <s> volume_up/volume_down/volume_mute, lock/unlock

Credentials (refresh token, never the password) are kept in the desktop keyring
through secret-tool, falling back to a 0600 file in ~/.local/state.
"""

import base64
import http.server
import json
import os
import re
import secrets
import select
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

# A fixed loopback client. Home Assistant accepts loopback client ids without
# fetching them, and the redirect lives on the same origin.
CALLBACK_PORT = 47291
CLIENT_ID = f"http://127.0.0.1:{CALLBACK_PORT}/"
REDIRECT_URI = f"http://127.0.0.1:{CALLBACK_PORT}/auth/callback"

KEYRING_SERVICE = "omarchy-home-assistant"
STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "omarchy-home-assistant")

ENTITY_RE = re.compile(r"^[a-z0-9_]+\.[a-z0-9_]+$")
UUID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
MAX_WATCH = 16
MAX_STR = 120
MAX_FRAME = 64 * 1024 * 1024
HTTP_TIMEOUT = 10


class HAError(Exception):
  def __init__(self, message, code="error"):
    super().__init__(message)
    self.code = code


def out(obj):
  sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
  sys.stdout.flush()


def clip(value, limit=MAX_STR):
  text = "" if value is None else str(value)
  text = text.replace("\n", " ").replace("\r", " ")
  return text if len(text) <= limit else text[: limit - 1] + "…"


def valid_url(url):
  try:
    parts = urllib.parse.urlsplit(url)
  except ValueError:
    return False
  return parts.scheme in ("http", "https") and bool(parts.hostname) and not parts.username and not parts.password


def norm_url(url):
  return url.rstrip("/")


def check_uuid(uuid):
  if not UUID_RE.match(uuid or ""):
    raise HAError("invalid server id")
  return uuid


def check_entity(entity_id):
  if not ENTITY_RE.match(entity_id or ""):
    raise HAError(f"invalid entity id: {clip(entity_id, 60)}")
  return entity_id


# ---------------------------------------------------------------- discovery

def unescape_avahi(text):
  return re.sub(r"\\(\d{3})", lambda m: chr(int(m.group(1))), text)


def parse_txt(field):
  txt = {}
  for item in re.findall(r'"((?:[^"\\]|\\.)*)"', field):
    item = unescape_avahi(item)
    if "=" in item:
      key, value = item.split("=", 1)
      txt[key] = value
  return txt


def discover():
  if not shutil.which("avahi-browse"):
    raise HAError("avahi-browse is not installed (pacman -S avahi)", "no-avahi")
  try:
    proc = subprocess.run(
      ["avahi-browse", "-rptk", "_home-assistant._tcp"],
      capture_output=True, text=True, timeout=8, check=False,
    )
    output = proc.stdout
  except subprocess.TimeoutExpired as exc:
    output = exc.stdout or ""
    if isinstance(output, bytes):
      output = output.decode("utf-8", "replace")

  servers = {}
  for line in output.splitlines():
    if not line.startswith("="):
      continue
    parts = line.split(";", 9)
    if len(parts) < 10:
      continue
    _, _iface, proto, name, _stype, _domain, _host, address, port, txt_field = parts
    txt = parse_txt(txt_field)
    uuid = txt.get("uuid") or ""
    if not UUID_RE.match(uuid):
      continue
    url = ""
    for key in ("internal_url", "base_url", "external_url"):
      candidate = txt.get(key, "")
      if candidate and valid_url(candidate):
        url = norm_url(candidate)
        break
    if not url:
      try:
        host = f"[{address}]" if proto == "IPv6" else address
        url = f"http://{host}:{int(port)}"
      except ValueError:
        continue
    entry = {
      "uuid": uuid,
      "name": clip(txt.get("location_name") or unescape_avahi(name), 60),
      "url": clip(url, 200),
      "version": clip(txt.get("version", ""), 40),
    }
    # Prefer an IPv4 sighting, which is what the TXT urls usually point at.
    if uuid not in servers or proto == "IPv4":
      servers[uuid] = entry

  stored = set(list_stored())
  result = sorted(servers.values(), key=lambda s: s["name"].lower())
  for server in result:
    server["loggedIn"] = server["uuid"] in stored
  return result


# -------------------------------------------------------------- credentials

def have_secret_tool():
  return shutil.which("secret-tool") is not None


def cred_file(uuid):
  return os.path.join(STATE_DIR, f"{check_uuid(uuid)}.json")


def save_creds(uuid, creds):
  payload = json.dumps(creds)
  if have_secret_tool():
    proc = subprocess.run(
      ["secret-tool", "store", "--label", f"Omarchy Home Assistant ({clip(creds.get('name', uuid), 40)})",
       "service", KEYRING_SERVICE, "server", uuid],
      input=payload, text=True, capture_output=True, timeout=15, check=False,
    )
    if proc.returncode == 0:
      try:
        os.remove(cred_file(uuid))
      except FileNotFoundError:
        pass
      return
  os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
  path = cred_file(uuid)
  fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
  with os.fdopen(fd, "w") as handle:
    handle.write(payload)


def load_creds(uuid):
  check_uuid(uuid)
  if have_secret_tool():
    proc = subprocess.run(
      ["secret-tool", "lookup", "service", KEYRING_SERVICE, "server", uuid],
      capture_output=True, text=True, timeout=15, check=False,
    )
    if proc.returncode == 0 and proc.stdout.strip():
      try:
        return json.loads(proc.stdout)
      except json.JSONDecodeError:
        pass
  try:
    with open(cred_file(uuid)) as handle:
      return json.load(handle)
  except (FileNotFoundError, json.JSONDecodeError):
    raise HAError("not logged in to this server", "auth")


def delete_creds(uuid):
  check_uuid(uuid)
  if have_secret_tool():
    subprocess.run(["secret-tool", "clear", "service", KEYRING_SERVICE, "server", uuid],
                   capture_output=True, timeout=15, check=False)
  try:
    os.remove(cred_file(uuid))
  except FileNotFoundError:
    pass


def list_stored():
  found = []
  if have_secret_tool():
    proc = subprocess.run(
      ["secret-tool", "search", "--all", "service", KEYRING_SERVICE],
      capture_output=True, text=True, timeout=15, check=False,
    )
    for line in (proc.stdout + "\n" + proc.stderr).splitlines():
      match = re.match(r"^attribute\.server = (\S+)$", line.strip())
      if match and UUID_RE.match(match.group(1)):
        found.append(match.group(1))
  if os.path.isdir(STATE_DIR):
    for name in os.listdir(STATE_DIR):
      if name.endswith(".json") and UUID_RE.match(name[:-5]):
        found.append(name[:-5])
  return sorted(set(found))


# --------------------------------------------------------------------- oauth

def post_form(url, fields):
  data = urllib.parse.urlencode(fields).encode()
  req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/x-www-form-urlencoded"})
  try:
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
      return json.loads(resp.read(1024 * 1024))
  except urllib.error.HTTPError as exc:
    body = exc.read(4096).decode("utf-8", "replace")
    if exc.code in (400, 401, 403):
      raise HAError(f"Home Assistant refused the credentials ({exc.code})", "auth")
    raise HAError(f"HTTP {exc.code}: {clip(body)}")
  except (urllib.error.URLError, OSError, TimeoutError) as exc:
    raise HAError(f"cannot reach Home Assistant: {clip(exc)}", "offline")


CALLBACK_PAGE = b"""<!doctype html><meta charset=utf-8><title>Omarchy</title>
<style>body{font:16px system-ui;display:grid;place-items:center;height:90vh;background:#111;color:#eee}</style>
<p>%s You can close this tab.</p>"""


def login(uuid, url, name):
  check_uuid(uuid)
  if not valid_url(url):
    raise HAError("invalid server url")
  url = norm_url(url)
  state = secrets.token_urlsafe(24)
  result = {}
  done = threading.Event()

  class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
      pass

    def do_GET(self):
      parsed = urllib.parse.urlsplit(self.path)
      if parsed.path != "/auth/callback":
        self.send_response(404)
        self.end_headers()
        return
      query = urllib.parse.parse_qs(parsed.query)
      ok = query.get("state", [""])[0] == state and query.get("code", [""])[0]
      if ok:
        result["code"] = query["code"][0]
      self.send_response(200 if ok else 400)
      self.send_header("Content-Type", "text/html; charset=utf-8")
      self.end_headers()
      self.wfile.write(CALLBACK_PAGE % (b"Logged in to Home Assistant." if ok else b"Login failed."))
      if ok:
        done.set()

  try:
    server = http.server.HTTPServer(("127.0.0.1", CALLBACK_PORT), Handler)
  except OSError:
    raise HAError(f"port {CALLBACK_PORT} is busy; is another login running?")
  server.timeout = 1

  authorize = f"{url}/auth/authorize?" + urllib.parse.urlencode({
    "response_type": "code",
    "client_id": CLIENT_ID,
    "redirect_uri": REDIRECT_URI,
    "state": state,
  })
  subprocess.Popen(["xdg-open", authorize], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
  out({"type": "progress", "message": "browser"})

  deadline = time.time() + 300
  try:
    while not done.is_set() and time.time() < deadline:
      server.handle_request()
  finally:
    server.server_close()
  if "code" not in result:
    raise HAError("login timed out", "timeout")

  tokens = post_form(f"{url}/auth/token", {
    "grant_type": "authorization_code",
    "code": result["code"],
    "client_id": CLIENT_ID,
  })
  refresh = tokens.get("refresh_token")
  if not refresh:
    raise HAError("Home Assistant returned no refresh token")
  save_creds(uuid, {"url": url, "name": name or uuid, "refresh_token": refresh, "client_id": CLIENT_ID})
  return {"type": "done", "uuid": uuid, "url": url}


def access_token(creds):
  tokens = post_form(f"{creds['url']}/auth/token", {
    "grant_type": "refresh_token",
    "refresh_token": creds["refresh_token"],
    "client_id": creds.get("client_id", CLIENT_ID),
  })
  token = tokens.get("access_token")
  if not token:
    raise HAError("no access token", "auth")
  return token


# ----------------------------------------------------------------- websocket

class WebSocket:
  """Minimal RFC 6455 client: text frames, ping/pong, fragmentation."""

  def __init__(self, url, timeout=HTTP_TIMEOUT):
    parts = urllib.parse.urlsplit(url)
    secure = parts.scheme == "https"
    host = parts.hostname
    port = parts.port or (443 if secure else 80)
    try:
      sock = socket.create_connection((host, port), timeout=timeout)
      if secure:
        sock = ssl.create_default_context().wrap_socket(sock, server_hostname=host)
    except OSError as exc:
      raise HAError(f"cannot reach Home Assistant: {clip(exc)}", "offline")
    self.sock = sock
    self.buf = b""
    key = base64.b64encode(os.urandom(16)).decode()
    hostport = parts.netloc.rsplit("@", 1)[-1]
    request = (
      f"GET /api/websocket HTTP/1.1\r\nHost: {hostport}\r\nUpgrade: websocket\r\n"
      f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
    )
    sock.sendall(request.encode())
    head = b""
    while b"\r\n\r\n" not in head:
      chunk = sock.recv(4096)
      if not chunk or len(head) > 65536:
        raise HAError("websocket handshake failed", "offline")
      head += chunk
    head, self.buf = head.split(b"\r\n\r\n", 1)
    if b" 101 " not in head.split(b"\r\n", 1)[0]:
      raise HAError("websocket handshake refused", "offline")
    self.next_id = 1

  def _read(self, n):
    while len(self.buf) < n:
      chunk = self.sock.recv(65536)
      if not chunk:
        raise HAError("connection closed", "offline")
      self.buf += chunk
    data, self.buf = self.buf[:n], self.buf[n:]
    return data

  def send_frame(self, opcode, payload):
    header = bytes([0x80 | opcode])
    n = len(payload)
    if n < 126:
      header += bytes([0x80 | n])
    elif n < 65536:
      header += bytes([0x80 | 126]) + struct.pack("!H", n)
    else:
      header += bytes([0x80 | 127]) + struct.pack("!Q", n)
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    self.sock.sendall(header + mask + masked)

  def send(self, obj):
    self.send_frame(0x1, json.dumps(obj).encode())

  def recv(self):
    message = b""
    while True:
      b1, b2 = self._read(2)
      fin, opcode = b1 & 0x80, b1 & 0x0F
      n = b2 & 0x7F
      if n == 126:
        n = struct.unpack("!H", self._read(2))[0]
      elif n == 127:
        n = struct.unpack("!Q", self._read(8))[0]
      if n > MAX_FRAME or len(message) + n > MAX_FRAME:
        raise HAError("message too large", "offline")
      mask = self._read(4) if b2 & 0x80 else None
      payload = self._read(n)
      if mask:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
      if opcode == 0x8:
        raise HAError("connection closed", "offline")
      if opcode == 0x9:
        self.send_frame(0xA, payload)
        continue
      if opcode == 0xA:
        continue
      message += payload
      if fin:
        return json.loads(message)

  def pending(self, timeout):
    if self.buf:
      return True
    if isinstance(self.sock, ssl.SSLSocket) and self.sock.pending():
      return True
    ready, _, _ = select.select([self.sock], [], [], timeout)
    return bool(ready)

  def close(self):
    try:
      self.send_frame(0x8, b"")
    except OSError:
      pass
    self.sock.close()


def connect(uuid):
  creds = load_creds(uuid)
  token = access_token(creds)
  ws = WebSocket(creds["url"])
  hello = ws.recv()
  if hello.get("type") != "auth_required":
    raise HAError("unexpected websocket greeting", "offline")
  ws.send({"type": "auth", "access_token": token})
  reply = ws.recv()
  if reply.get("type") != "auth_ok":
    raise HAError("websocket authentication failed", "auth")
  return ws


def call(ws, payload):
  msg_id = ws.next_id
  ws.next_id += 1
  ws.send(dict(payload, id=msg_id))
  while True:
    reply = ws.recv()
    if reply.get("id") == msg_id and reply.get("type") == "result":
      if not reply.get("success"):
        err = reply.get("error") or {}
        raise HAError(clip(err.get("message") or err.get("code") or "command failed"), err.get("code", "error"))
      return reply.get("result")


def try_call(ws, payload):
  try:
    return call(ws, payload)
  except HAError:
    return None


# --------------------------------------------------------------- suggestions

def collect_entities(node, found, depth=0):
  """Every entity id referenced anywhere in a dashboard config."""
  if depth > 40 or len(found) > 500:
    return
  if isinstance(node, str):
    if ENTITY_RE.match(node) and node not in found:
      found.append(node)
  elif isinstance(node, list):
    for item in node:
      collect_entities(item, found, depth + 1)
  elif isinstance(node, dict):
    for key, value in node.items():
      if key in ("entity", "entity_id", "entities", "favorite_entities", "cards", "sections",
                 "views", "badges", "strategy", "card", "elements", "rows", "items", "target"):
        collect_entities(value, found, depth + 1)
      elif isinstance(value, (dict, list)):
        collect_entities(value, found, depth + 1)


def describe(state):
  attrs = state.get("attributes") or {}
  return {
    "entity_id": state["entity_id"],
    "name": clip(attrs.get("friendly_name") or state["entity_id"], 80),
    "state": clip(state.get("state"), 60),
    "unit": clip(attrs.get("unit_of_measurement") or "", 16),
    "deviceClass": clip(attrs.get("device_class") or "", 32),
  }


def suggest(uuid):
  ws = connect(uuid)
  try:
    states = {s["entity_id"]: s for s in (call(ws, {"type": "get_states"}) or [])
              if isinstance(s, dict) and ENTITY_RE.match(str(s.get("entity_id", "")))}

    user_core = (try_call(ws, {"type": "frontend/get_user_data", "key": "core"}) or {}).get("value") or {}
    system_core = (try_call(ws, {"type": "frontend/get_system_data", "key": "core"}) or {}).get("value") or {}
    default_panel = user_core.get("default_panel") or system_core.get("default_panel") or "home"

    favorites, dashboard = [], []
    if default_panel != "home":
      config = try_call(ws, {"type": "lovelace/config", "url_path": None if default_panel == "lovelace" else default_panel, "force": False})
      if isinstance(config, dict):
        collect_entities(config, dashboard)
      else:
        default_panel = "home"
    home = (try_call(ws, {"type": "frontend/get_system_data", "key": "home"}) or {}).get("value") or {}
    for entity_id in home.get("favorite_entities") or []:
      if isinstance(entity_id, str) and ENTITY_RE.match(entity_id):
        favorites.append(entity_id)
    if default_panel != "home":
      # A custom default dashboard: what it shows is the closest thing to favorites.
      favorites, dashboard = dashboard, favorites

    common = (try_call(ws, {"type": "usage_prediction/common_control"}) or {}).get("entities") or []
  finally:
    ws.close()

  seen, suggestions = set(), []
  for source, ids in (("favorite", favorites), ("common", common), ("dashboard", dashboard)):
    for entity_id in ids:
      if entity_id in seen or entity_id not in states:
        continue
      seen.add(entity_id)
      suggestions.append(dict(describe(states[entity_id]), source=source))
      if len(suggestions) >= 40:
        break

  everything = [describe(s) for s in states.values()]
  everything.sort(key=lambda e: e["name"].lower())
  return {
    "defaultPanel": clip(default_panel, 60),
    "suggestions": suggestions,
    "entities": everything[:3000],
  }


# --------------------------------------------------------------------- watch

PICTURE_RE = re.compile(r"^/api/camera_proxy/[a-z0-9_]+\.[a-z0-9_]+\?token=[A-Za-z0-9_-]{1,128}$")


def compact_state(entity_id, s, a):
  result = {
    "entity_id": entity_id,
    "name": clip(a.get("friendly_name") or entity_id, 80),
    "state": clip(s, 60),
    "unit": clip(a.get("unit_of_measurement") or "", 16),
    "deviceClass": clip(a.get("device_class") or "", 32),
  }
  volume = a.get("volume_level")
  if isinstance(volume, (int, float)) and 0 <= volume <= 1:
    result["volume"] = round(float(volume), 3)
  if a.get("is_volume_muted") is True:
    result["muted"] = True
  # Camera stills come from a short-lived, per-entity token Home Assistant
  # rotates every few minutes; only that exact path shape is passed on.
  picture = a.get("entity_picture")
  if isinstance(picture, str) and PICTURE_RE.match(picture):
    result["picture"] = picture
  return result


def watch(uuid, entity_ids):
  entity_ids = [check_entity(e) for e in entity_ids][:MAX_WATCH]
  backoff = 2
  while True:
    ws = None
    try:
      ws = connect(uuid)
      backoff = 2
      sub_id = ws.next_id
      ws.next_id += 1
      ws.send({"id": sub_id, "type": "subscribe_entities", "entity_ids": entity_ids})
      cache = {}
      out({"type": "status", "connected": True})
      last_ping = time.time()
      while True:
        if not ws.pending(25):
          if time.time() - last_ping > 50:
            raise HAError("connection stalled", "offline")
          ping_id = ws.next_id
          ws.next_id += 1
          ws.send({"id": ping_id, "type": "ping"})
          continue
        msg = ws.recv()
        if msg.get("type") == "pong":
          last_ping = time.time()
          continue
        last_ping = time.time()
        if msg.get("id") != sub_id:
          continue
        if msg.get("type") == "result" and not msg.get("success"):
          raise HAError("subscription failed")
        event = msg.get("event")
        if not isinstance(event, dict):
          continue
        for entity_id, full in (event.get("a") or {}).items():
          cache[entity_id] = {"s": full.get("s"), "a": dict(full.get("a") or {})}
        for entity_id, diff in (event.get("c") or {}).items():
          entry = cache.setdefault(entity_id, {"s": None, "a": {}})
          plus = diff.get("+") or {}
          if "s" in plus:
            entry["s"] = plus["s"]
          entry["a"].update(plus.get("a") or {})
          for key in (diff.get("-") or {}).get("a") or []:
            entry["a"].pop(key, None)
        for entity_id in event.get("r") or []:
          cache.pop(entity_id, None)
        out({"type": "states", "states": [
          compact_state(e, cache[e]["s"], cache[e]["a"]) for e in entity_ids if e in cache
        ]})
    except HAError as exc:
      out({"type": "status", "connected": False, "code": exc.code, "error": clip(exc)})
      if exc.code == "auth":
        return 2
    except (OSError, ValueError, KeyError) as exc:
      out({"type": "status", "connected": False, "code": "offline", "error": clip(exc)})
    finally:
      if ws:
        ws.close()
    time.sleep(backoff)
    backoff = min(backoff * 2, 60)


# -------------------------------------------------------------------- toggle

TOGGLE_DOMAINS = {"light", "switch", "fan", "input_boolean", "automation", "cover",
                  "climate", "humidifier", "siren", "valve", "water_heater", "vacuum", "remote", "group"}


def toggle(uuid, entity_id):
  check_entity(entity_id)
  domain = entity_id.split(".", 1)[0]
  if domain not in TOGGLE_DOMAINS | {"lock", "button", "input_button", "scene", "script"}:
    raise HAError(f"{domain} entities cannot be toggled")
  ws = connect(uuid)
  try:
    if domain == "lock":
      state = next((s for s in call(ws, {"type": "get_states"}) if s.get("entity_id") == entity_id), None)
      service = "unlock" if state and state.get("state") == "locked" else "lock"
    elif domain in ("button", "input_button"):
      service = "press"
    elif domain in ("scene", "script"):
      service = "turn_on"
    elif domain in TOGGLE_DOMAINS:
      service = "toggle"
    else:
      raise HAError(f"{domain} entities cannot be toggled")
    call(ws, {"type": "call_service", "domain": domain, "service": service, "target": {"entity_id": entity_id}})
  finally:
    ws.close()
  return {"ok": True}


# Explicit actions the panel offers beyond toggling, per domain.
ACTIONS = {
  "media_player": {"volume_up", "volume_down", "volume_mute"},
  "lock": {"lock", "unlock"},
}


def action(uuid, entity_id, service):
  check_entity(entity_id)
  domain = entity_id.split(".", 1)[0]
  if service not in ACTIONS.get(domain, ()):
    raise HAError(f"{domain}.{clip(service, 30)} is not allowed")
  data = {}
  if service == "volume_mute":
    ws = connect(uuid)
    try:
      state = next((s for s in call(ws, {"type": "get_states"}) if s.get("entity_id") == entity_id), None)
      data["is_volume_muted"] = not ((state or {}).get("attributes") or {}).get("is_volume_muted", False)
      call(ws, {"type": "call_service", "domain": domain, "service": service, "service_data": data,
                "target": {"entity_id": entity_id}})
    finally:
      ws.close()
    return {"ok": True}
  ws = connect(uuid)
  try:
    call(ws, {"type": "call_service", "domain": domain, "service": service, "target": {"entity_id": entity_id}})
  finally:
    ws.close()
  return {"ok": True}


# ---------------------------------------------------------------------- main

def main(argv):
  if not argv:
    print(__doc__, file=sys.stderr)
    return 64
  cmd, args = argv[0], argv[1:]
  try:
    if cmd == "discover":
      out({"servers": discover()})
    elif cmd == "servers":
      out({"servers": list_stored()})
    elif cmd == "login" and len(args) >= 2:
      out(login(args[0], args[1], args[2] if len(args) > 2 else ""))
    elif cmd == "logout" and len(args) == 1:
      delete_creds(args[0])
      out({"ok": True})
    elif cmd == "suggest" and len(args) == 1:
      out(suggest(args[0]))
    elif cmd == "watch" and len(args) >= 2:
      check_uuid(args[0])
      return watch(args[0], args[1:])
    elif cmd == "toggle" and len(args) == 2:
      out(toggle(args[0], args[1]))
    elif cmd == "action" and len(args) == 3:
      out(action(args[0], args[1], args[2]))
    else:
      print(__doc__, file=sys.stderr)
      return 64
  except HAError as exc:
    out({"error": clip(exc, 300), "code": exc.code})
    return 1
  except (OSError, ValueError) as exc:
    out({"error": f"cannot reach Home Assistant: {clip(exc, 200)}", "code": "offline"})
    return 1
  except KeyboardInterrupt:
    return 130
  return 0


if __name__ == "__main__":
  sys.exit(main(sys.argv[1:]))
