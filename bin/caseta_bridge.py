#!/usr/bin/env python3
"""Lutron Caseta bridge helper for the io.github.demirhere.caseta Omarchy plugin.

Subcommands:
  daemon            Hold a LEAP connection open. Emits JSON lines on stdout
                    (status / snapshot / update / error events) and reads JSON
                    command lines on stdin. Exits when stdin closes.
  pair [host]       Pair with a Smart Bridge (press its button when asked) and
                    store the client certificate under ~/.config/omarchy-caseta.
  discover          Print Lutron bridges found over mDNS as JSON.
  status            Print the stored pairing as JSON.
"""

import asyncio
import json
import logging
import os
import signal
import socket
import ssl
import subprocess
import sys
import time
from pathlib import Path

HOME = Path.home()
CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME") or HOME / ".config") / "omarchy-caseta"
STATE_DIR = Path(os.environ.get("XDG_STATE_HOME") or HOME / ".local/state") / "omarchy-caseta"
BRIDGE_FILE = CONFIG_DIR / "bridge.json"
KEY_FILE = CONFIG_DIR / "client.key"
CERT_FILE = CONFIG_DIR / "client.crt"
CA_FILE = CONFIG_DIR / "bridge-ca.crt"
LEVELS_FILE = STATE_DIR / "last-levels.json"

LEAP_PORT = 8081
DOMAINS = ("light", "switch", "fan", "cover")
FAN_SPEEDS = ["Off", "Low", "Medium", "MediumHigh", "High"]
# How long a device must stay unreachable before we look for the bridge at a
# new address (DHCP moves it) using the MAC recorded at pairing time.
REDISCOVER_AFTER = 20.0
# Zone updates for a device with commands in flight are held back until the
# queue drains, so a slider drag does not replay its intermediate levels.
SETTLE_SECONDS = 0.4


def emit(event, **fields):
    sys.stdout.write(json.dumps({"event": event, **fields}) + "\n")
    sys.stdout.flush()


def load_bridge_config():
    try:
        cfg = json.loads(BRIDGE_FILE.read_text())
    except (OSError, ValueError):
        return None
    if not cfg.get("host"):
        return None
    for path in (KEY_FILE, CERT_FILE, CA_FILE):
        if not path.is_file():
            return None
    return cfg


def save_bridge_config(cfg):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(CONFIG_DIR, 0o700)
    tmp = BRIDGE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(cfg, indent=2) + "\n")
    tmp.replace(BRIDGE_FILE)


def discover(timeout=6):
    """Find Lutron bridges with avahi. Returns [{host, name, mac, type}]."""
    try:
        out = subprocess.run(
            ["avahi-browse", "-rtpk", "_lutron._tcp"],
            capture_output=True, text=True, timeout=timeout,
        ).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    found = {}
    for line in out.splitlines():
        parts = line.split(";", 9)
        if len(parts) < 10 or parts[0] != "=" or parts[2] != "IPv4":
            continue
        txt = {}
        for item in parts[9].split('" "'):
            key, _, value = item.strip('"').partition("=")
            txt[key] = value
        mac = txt.get("MACADDR", "").lower()
        found[mac or parts[7]] = {
            "host": parts[7],
            "name": parts[6].removesuffix(".local"),
            "mac": mac,
            "type": txt.get("SYSTYPE", ""),
        }
    return list(found.values())


# ---------------------------------------------------------------- daemon


class LastLevels:
    """Remembers each dimmer's last non-zero level so 'on' restores it."""

    def __init__(self):
        try:
            self.levels = json.loads(LEVELS_FILE.read_text())
        except (OSError, ValueError):
            self.levels = {}

    def get(self, device_id):
        level = self.levels.get(device_id)
        return level if isinstance(level, int) and 0 < level <= 100 else 100

    def remember(self, device_id, level):
        if not isinstance(level, int) or level <= 0 or self.levels.get(device_id) == level:
            return
        self.levels[device_id] = level
        try:
            STATE_DIR.mkdir(parents=True, exist_ok=True)
            tmp = LEVELS_FILE.with_suffix(".tmp")
            tmp.write_text(json.dumps(self.levels))
            tmp.replace(LEVELS_FILE)
        except OSError:
            pass


class LastErrorHandler(logging.Handler):
    """Keeps pylutron_caseta's most recent warning for the status line."""

    def __init__(self):
        super().__init__(logging.WARNING)
        self.message = ""

    def emit(self, record):
        try:
            self.message = record.getMessage()
        except Exception:
            pass


class Daemon:
    def __init__(self, cfg):
        from pylutron_caseta.leap import open_connection
        from pylutron_caseta.smartbridge import Smartbridge

        self.cfg = cfg
        self.host = cfg["host"]
        self.levels = LastLevels()
        self.pending = {}
        self.workers = {}
        self.domains = {}
        self.subscribed = set()
        self.log = LastErrorHandler()
        logging.getLogger("pylutron_caseta").addHandler(self.log)
        logging.getLogger("pylutron_caseta").propagate = False

        loop = asyncio.get_running_loop()

        def tls_context():
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            ctx.minimum_version = ssl.TLSVersion.TLSv1_2
            ctx.load_verify_locations(str(CA_FILE))
            ctx.load_cert_chain(str(CERT_FILE), str(KEY_FILE))
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_REQUIRED
            return ctx

        async def connect():
            ctx = await loop.run_in_executor(None, tls_context)
            # Read self.host on every attempt so a rediscovered address is
            # picked up by the library's own reconnect loop.
            return await open_connection(
                self.host, LEAP_PORT, server_hostname="", ssl=ctx, family=socket.AF_INET
            )

        self.bridge = Smartbridge(connect)

    # -- state -----------------------------------------------------------

    def device_payload(self, dev):
        area_name = ""
        area = self.bridge.areas.get(dev.get("area")) if dev.get("area") else None
        if area:
            area_name = area.get("name", "")
        level = dev.get("current_state", -1)
        return {
            "id": dev["device_id"],
            "name": dev.get("device_name") or dev.get("name", ""),
            "area": area_name,
            "domain": self.domains.get(dev["device_id"], ""),
            "type": dev.get("type", ""),
            "model": dev.get("model", ""),
            "level": level if isinstance(level, int) else -1,
            "fan": dev.get("fan_speed"),
            "last": self.levels.get(dev["device_id"]),
        }

    def controllable(self):
        devices = []
        for domain in DOMAINS:
            for dev in self.bridge.get_devices_by_domain(domain):
                if not dev.get("zone") or dev.get("type") == "KeypadLED":
                    continue
                self.domains[dev["device_id"]] = domain
                devices.append(dev)
        return devices

    def snapshot(self):
        devices = self.controllable()
        for dev in devices:
            did = dev["device_id"]
            if did not in self.subscribed:
                self.bridge.add_subscriber(did, lambda did=did: self.on_zone(did))
                self.subscribed.add(did)
            if self.domains.get(did) == "light":
                self.levels.remember(did, dev.get("current_state"))
        payload = [self.device_payload(d) for d in devices]
        payload.sort(key=lambda d: (d["area"].lower(), d["name"].lower()))
        scenes = [
            {"id": s["scene_id"], "name": s["name"]}
            for s in self.bridge.get_scenes().values()
        ]
        scenes.sort(key=lambda s: int(s["id"]) if s["id"].isdigit() else 0)
        emit("snapshot", devices=payload, scenes=scenes, host=self.host)

    def emit_device(self, did):
        dev = self.bridge.devices.get(did)
        if dev is None:
            return
        if self.domains.get(did) == "light":
            self.levels.remember(did, dev.get("current_state"))
        emit("update", device=self.device_payload(dev))

    def on_zone(self, did):
        if did in self.workers:
            return
        self.emit_device(did)

    # -- commands --------------------------------------------------------

    def queue(self, did, kind, value):
        if did not in self.bridge.devices:
            emit("error", message=f"Unknown device {did}")
            return
        self.pending[did] = (kind, value)
        if did not in self.workers:
            self.workers[did] = asyncio.get_running_loop().create_task(self.drain(did))

    async def drain(self, did):
        try:
            while did in self.pending:
                kind, value = self.pending.pop(did)
                try:
                    if kind == "fan":
                        await self.bridge.set_fan(did, value)
                    else:
                        await self.bridge.set_value(did, value)
                except Exception as ex:  # noqa: BLE001 - reported to the panel
                    name = self.bridge.devices.get(did, {}).get("device_name", did)
                    emit("error", message=f"{name}: {ex or type(ex).__name__}")
            await asyncio.sleep(SETTLE_SECONDS)
        finally:
            self.workers.pop(did, None)
            self.emit_device(did)

    def is_on(self, dev):
        if self.domains.get(dev["device_id"]) == "fan":
            return (dev.get("fan_speed") or "Off") != "Off"
        return (dev.get("current_state") or 0) > 0

    def turn_on(self, did):
        domain = self.domains.get(did)
        if domain == "fan":
            self.queue(did, "fan", "Medium")
        elif domain == "light":
            self.queue(did, "level", self.levels.get(did))
        else:
            self.queue(did, "level", 100)

    def turn_off(self, did):
        if self.domains.get(did) == "fan":
            self.queue(did, "fan", "Off")
        else:
            self.queue(did, "level", 0)

    async def handle(self, cmd):
        action = cmd.get("cmd")
        did = str(cmd.get("id", ""))
        if action == "refresh":
            if self.bridge.logged_in:
                self.snapshot()
            return
        if not self.bridge.logged_in:
            emit("error", message="Bridge is not connected")
            return
        if action == "set":
            level = max(0, min(100, int(cmd.get("level", 0))))
            self.queue(did, "level", level)
        elif action == "fan":
            speed = cmd.get("speed")
            if speed in FAN_SPEEDS:
                self.queue(did, "fan", speed)
        elif action == "on":
            self.turn_on(did)
        elif action == "off":
            self.turn_off(did)
        elif action == "toggle":
            dev = self.bridge.devices.get(did)
            if dev is None:
                emit("error", message=f"Unknown device {did}")
            elif self.is_on(dev):
                self.turn_off(did)
            else:
                self.turn_on(did)
        elif action == "restore":
            # [{id, level}] captured by the panel before an "all off".
            for item in cmd.get("devices", []):
                rid = str(item.get("id", ""))
                if self.domains.get(rid) == "fan":
                    speed = item.get("fan")
                    self.queue(rid, "fan", speed if speed in FAN_SPEEDS else "Medium")
                else:
                    self.queue(rid, "level", max(1, min(100, int(item.get("level", 100)))))
        elif action == "all-off":
            for dev in self.controllable():
                if self.domains[dev["device_id"]] in ("light", "switch") and self.is_on(dev):
                    self.turn_off(dev["device_id"])
        elif action == "scene":
            await self.bridge.activate_scene(did)
        else:
            emit("error", message=f"Unknown command {action!r}")

    # -- lifecycle -------------------------------------------------------

    async def watch(self):
        """Report connection state and rediscover a bridge that moved."""
        last = None
        down_since = time.monotonic()
        while True:
            state = "connected" if self.bridge.logged_in else "connecting"
            if state == "connected":
                down_since = None
            elif down_since is None:
                down_since = time.monotonic()
            if state != last:
                if state == "connected":
                    self.snapshot()
                emit("status", state=state, host=self.host, message="")
                last = state
            elif state == "connecting" and self.log.message:
                emit("status", state=state, host=self.host, message=self.log.message)
                self.log.message = ""
            if (
                state == "connecting"
                and down_since is not None
                and time.monotonic() - down_since > REDISCOVER_AFTER
                and self.cfg.get("mac")
            ):
                down_since = time.monotonic()
                await self.rediscover()
            await asyncio.sleep(0.5)

    async def rediscover(self):
        loop = asyncio.get_running_loop()
        found = await loop.run_in_executor(None, discover)
        for bridge in found:
            if bridge["mac"] == self.cfg["mac"] and bridge["host"] != self.host:
                self.host = bridge["host"]
                self.cfg["host"] = bridge["host"]
                save_bridge_config(self.cfg)
                emit("status", state="connecting", host=self.host,
                     message=f"Bridge moved to {self.host}")
                return

    async def commands(self):
        loop = asyncio.get_running_loop()
        reader = asyncio.StreamReader()
        await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin)
        while True:
            line = await reader.readline()
            if not line:
                return
            try:
                cmd = json.loads(line)
            except ValueError:
                emit("error", message="Malformed command")
                continue
            try:
                await self.handle(cmd)
            except Exception as ex:  # noqa: BLE001 - reported to the panel
                emit("error", message=str(ex) or type(ex).__name__)

    async def run(self):
        loop = asyncio.get_running_loop()
        emit("status", state="connecting", host=self.host, message="")
        # connect() resolves after the first login and the library reconnects
        # on its own from then on. It only fails outright when a login is
        # refused, which the library never recovers from, so exit and let the
        # shell restart the whole helper.
        connect_task = loop.create_task(self.bridge.connect())
        watch_task = loop.create_task(self.watch())
        commands_task = loop.create_task(self.commands())
        try:
            await asyncio.wait({connect_task, commands_task}, return_when=asyncio.FIRST_COMPLETED)
            if not commands_task.done() and (connect_task.cancelled() or connect_task.exception()):
                ex = None if connect_task.cancelled() else connect_task.exception()
                emit("status", state="error", host=self.host,
                     message=str(ex or self.log.message or "Login to the bridge failed"))
                return 1
            await commands_task
            return 0
        finally:
            for task in (watch_task, connect_task, commands_task):
                task.cancel()
            try:
                await self.bridge.close()
            except Exception:  # noqa: BLE001
                pass


async def run_daemon():
    cfg = load_bridge_config()
    if cfg is None:
        emit("status", state="unpaired", host="", message="No paired bridge")
        return 3
    try:
        daemon = Daemon(cfg)
    except ImportError:
        emit("status", state="not-installed", host=cfg.get("host", ""),
             message="pylutron-caseta is not installed")
        return 4
    loop = asyncio.get_running_loop()
    main = asyncio.current_task()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, main.cancel)
    try:
        return await daemon.run()
    except asyncio.CancelledError:
        return 0


# ---------------------------------------------------------------- pairing


def choose_bridge(host):
    if host:
        return {"host": host, "name": "", "mac": "", "type": ""}
    print("Looking for Lutron bridges on the network...")
    found = discover()
    if len(found) == 1:
        bridge = found[0]
        print(f"Found {bridge['type'] or 'bridge'} {bridge['name']} at {bridge['host']}")
        return bridge
    if found:
        for i, bridge in enumerate(found, 1):
            print(f"  {i}. {bridge['name']} ({bridge['type']}) at {bridge['host']}")
        pick = input("Which bridge? [1] ").strip() or "1"
        return found[int(pick) - 1]
    print("No bridge answered over mDNS.")
    entered = input("Bridge IP address: ").strip()
    if not entered:
        sys.exit(1)
    return {"host": entered, "name": "", "mac": "", "type": ""}


async def run_pair(host):
    from pylutron_caseta.pairing import async_pair

    bridge = choose_bridge(host)
    if not bridge["mac"]:
        for other in discover():
            if other["host"] == bridge["host"]:
                bridge = other

    def ready():
        print()
        print("Press the small black button on the back of the Smart Bridge now.")
        print("(Waiting up to 3 minutes...)")

    print(f"Connecting to {bridge['host']}...")
    data = await async_pair(bridge["host"], ready)

    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(CONFIG_DIR, 0o700)
    for path, content in ((KEY_FILE, data["key"]), (CERT_FILE, data["cert"]), (CA_FILE, data["ca"])):
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as fh:
            fh.write(content)
    save_bridge_config({
        "host": bridge["host"],
        "name": bridge["name"],
        "mac": bridge["mac"],
        "type": bridge["type"],
        "leapVersion": data.get("version"),
        "pairedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    })
    print(f"Paired with {bridge['name'] or bridge['host']} (LEAP {data.get('version')}).")
    print(f"Certificates saved in {CONFIG_DIR}")
    return 0


def main(argv):
    command = argv[1] if len(argv) > 1 else "daemon"
    if command == "daemon":
        return asyncio.run(run_daemon())
    if command == "pair":
        try:
            return asyncio.run(run_pair(argv[2] if len(argv) > 2 else ""))
        except (KeyboardInterrupt, EOFError):
            print("\nCancelled.")
            return 130
        except (asyncio.TimeoutError, TimeoutError):
            print("Timed out waiting for the bridge button. Run setup again to retry.")
            return 1
    if command == "discover":
        print(json.dumps(discover(), indent=2))
        return 0
    if command == "status":
        cfg = load_bridge_config()
        print(json.dumps(cfg or {}, indent=2))
        return 0 if cfg else 3
    print(__doc__.strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
