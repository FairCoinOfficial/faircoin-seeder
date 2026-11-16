#!/usr/bin/env python3
"""
faircoin-monitor — notice a sick FairCoin node in minutes, not months.

WHY THIS EXISTS (2026-11-16 incident)

  * fcnode2 split off the network on 2026-09-24 at height 166299. It holds a
    large staking wallet, so it kept extending its own branch; once that branch
    was 100 blocks deep (nMaxReorganizationDepth) it could never reorg back.
    Nobody noticed for 53 days.
  * fcbridge's node froze at height 105451 on 2026-08-13 (torn block files) and
    the bridge was blind to FairCoin for 3 months.
  * fcnode3 filled its disk with logs and stopped.

Every one of those was visible from the outside within minutes. This script runs
on one host (fcexplorer) from a systemd timer and checks every node over the
public P2P port — no RPC credentials on other hosts, nothing to install there:

  1. reachable      — version handshake succeeds;
  2. same chain     — the node's active chain contains our block at height
                      (lowest tip - CONFIRM_DEPTH). A split is caught while it is
                      a few blocks deep, long before it becomes permanent;
  3. keeping up     — its height is within LAG_BLOCKS of the best node, on two
                      consecutive runs (one-off propagation delay is ignored);
  4. our own tip    — the local node's tip is not older than STALE_TIP_SECONDS.

Alerts go to the journal (priority warning) and, when TELEGRAM_BOT_TOKEN and
TELEGRAM_CHAT_ID are set in /etc/faircoin-monitor.env, to Telegram. An alert is
sent when a problem appears, repeated every REMIND_SECONDS while it persists,
and a recovery message when it clears.
"""

import hashlib
import json
import os
import random
import socket
import struct
import subprocess
import sys
import time
import urllib.parse
import urllib.request

MAGIC = bytes.fromhex("a3d7e1b4")  # mainnet pchMessageStart
PROTOCOL_VERSION = 71000
P2P_PORT = 46372

CONFIRM_DEPTH = int(os.environ.get("CONFIRM_DEPTH", "6"))
LAG_BLOCKS = int(os.environ.get("LAG_BLOCKS", "10"))
STALE_TIP_SECONDS = int(os.environ.get("STALE_TIP_SECONDS", "1800"))
REMIND_SECONDS = int(os.environ.get("REMIND_SECONDS", "21600"))
TIMEOUT = float(os.environ.get("P2P_TIMEOUT", "15"))
STATE_FILE = os.environ.get("STATE_FILE", "/var/lib/faircoin-monitor/state.json")
CLI = os.environ.get("FAIRCOIN_CLI", "/usr/local/bin/faircoin-cli")
DATADIR = os.environ.get("FAIRCOIN_DATADIR", "/root/.faircoin")
# "name=ip name=ip ..." — every node we operate, including this host.
NODES = os.environ.get("NODES", "")


# ---------------------------------------------------------------- P2P client

def _dsha(data: bytes) -> bytes:
    return hashlib.sha256(hashlib.sha256(data).digest()).digest()


def _msg(cmd: str, payload: bytes) -> bytes:
    return (MAGIC + cmd.encode().ljust(12, b"\0") + struct.pack("<I", len(payload))
            + _dsha(payload)[:4] + payload)


def _netaddr(ip: str = "0.0.0.0", port: int = 0) -> bytes:
    return struct.pack("<Q", 1) + b"\0" * 10 + b"\xff\xff" + socket.inet_aton(ip) + struct.pack(">H", port)


def _compact(n: int) -> bytes:
    return bytes([n]) if n < 0xFD else b"\xfd" + struct.pack("<H", n)


def _read_compact(buf: bytes, off: int):
    first = buf[off]
    if first < 0xFD:
        return first, off + 1
    if first == 0xFD:
        return struct.unpack("<H", buf[off + 1:off + 3])[0], off + 3
    return struct.unpack("<I", buf[off + 1:off + 5])[0], off + 5


def _recv_exact(sock: socket.socket, n: int) -> bytes:
    out = b""
    while len(out) < n:
        chunk = sock.recv(n - len(out))
        if not chunk:
            raise EOFError("peer closed the connection")
        out += chunk
    return out


def _read_msg(sock: socket.socket):
    header = _recv_exact(sock, 24)
    if header[:4] != MAGIC:
        raise ValueError("wrong network magic")
    cmd = header[4:16].rstrip(b"\0").decode()
    length = struct.unpack("<I", header[16:20])[0]
    return cmd, _recv_exact(sock, length)


class Peer:
    """One short-lived P2P session: handshake, then getblocks queries."""

    def __init__(self, ip: str, port: int = P2P_PORT):
        self.sock = socket.create_connection((ip, port), timeout=TIMEOUT)
        payload = (struct.pack("<iQq", PROTOCOL_VERSION, 1, int(time.time()))
                   + _netaddr(ip, port) + _netaddr()
                   + struct.pack("<Q", random.getrandbits(64))
                   + bytes([len(b"/faircoin-monitor:1/")]) + b"/faircoin-monitor:1/"
                   + struct.pack("<i", 0))
        self.sock.sendall(_msg("version", payload))
        self.height = None
        self.user_agent = ""
        got_version = got_verack = False
        while not (got_version and got_verack):
            cmd, body = _read_msg(self.sock)
            if cmd == "version":
                off = 4 + 8 + 8 + 26 + 26 + 8
                ua_len = body[off]
                self.user_agent = body[off + 1:off + 1 + ua_len].decode(errors="replace")
                self.height = struct.unpack("<i", body[off + 1 + ua_len:off + 5 + ua_len])[0]
                self.sock.sendall(_msg("verack", b""))
                got_version = True
            elif cmd == "verack":
                got_verack = True

    def blocks_after(self, block_hash_hex: str):
        """
        Ask for the block hashes that follow `block_hash_hex` on the peer's active
        chain. If that block is NOT on its active chain, FindForkInGlobalIndex
        falls back to genesis and the reply starts at height 1 — which is how a
        split shows up. Unsolicited single-block announcements are skipped.
        """
        locator = bytes.fromhex(block_hash_hex)[::-1]
        payload = struct.pack("<i", PROTOCOL_VERSION) + _compact(1) + locator + b"\0" * 32
        self.sock.sendall(_msg("getblocks", payload))
        deadline = time.time() + TIMEOUT
        while time.time() < deadline:
            cmd, body = _read_msg(self.sock)
            if cmd == "ping":
                self.sock.sendall(_msg("pong", body))
                continue
            if cmd != "inv":
                continue
            count, off = _read_compact(body, 0)
            hashes = []
            for _ in range(count):
                inv_type = struct.unpack("<I", body[off:off + 4])[0]
                if inv_type == 2:  # MSG_BLOCK
                    hashes.append(body[off + 4:off + 36][::-1].hex())
                off += 36
            # Our query is CONFIRM_DEPTH blocks deep, so a real answer carries
            # several hashes; a lone hash is a new-tip announcement.
            if len(hashes) >= 2:
                return hashes
        raise TimeoutError("no getblocks answer")

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


# ---------------------------------------------------------------- local node

def cli(*args: str) -> str:
    out = subprocess.run([CLI, f"-datadir={DATADIR}", *args], capture_output=True,
                         text=True, timeout=30)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip() or f"faircoin-cli {args[0]} failed")
    return out.stdout.strip()


# ---------------------------------------------------------------- checks

def parse_nodes(spec: str):
    nodes = []
    for item in spec.split():
        name, _, ip = item.partition("=")
        if name and ip:
            nodes.append((name, ip))
    return nodes


def run_checks(nodes):
    """Return (problems: dict key->text, summary: list of lines)."""
    problems = {}
    summary = []

    try:
        local_height = int(cli("getblockcount"))
        tip_time = int(json.loads(cli("getblock", cli("getbestblockhash")))["time"])
    except Exception as exc:  # noqa: BLE001 — any failure here is the finding
        problems["local:rpc"] = f"local node RPC is not answering: {exc}"
        return problems, summary

    tip_age = int(time.time()) - tip_time
    if tip_age > STALE_TIP_SECONDS:
        problems["local:stale"] = f"local tip at {local_height} is {tip_age // 60} min old"

    peers = {}
    for name, ip in nodes:
        try:
            peers[name] = Peer(ip)
        except Exception as exc:  # noqa: BLE001
            problems[f"{name}:down"] = f"{name} ({ip}) unreachable on P2P: {exc}"

    heights = [p.height for p in peers.values() if p.height is not None] + [local_height]
    best = max(heights)
    check_height = min(heights) - CONFIRM_DEPTH
    try:
        ref_hash = cli("getblockhash", str(check_height))
        ref_next = cli("getblockhash", str(check_height + 1))
        genesis_next = cli("getblockhash", "1")
    except Exception as exc:  # noqa: BLE001
        problems["local:rpc"] = f"local node RPC failed during check: {exc}"
        ref_hash = None

    for name, peer in peers.items():
        lag = best - peer.height
        line = f"{name}: height {peer.height} ({peer.user_agent})"
        if ref_hash and check_height > 1:
            try:
                after = peer.blocks_after(ref_hash)
                if after[0] == ref_next:
                    line += f", same chain at {check_height}"
                else:
                    reason = ("does not have our block" if after[0] == genesis_next
                              else "follows a different block")
                    problems[f"{name}:fork"] = (
                        f"{name} is on a DIFFERENT CHAIN: at height {check_height} it "
                        f"{reason}. Stop staking on it and resync before the split "
                        f"is {100} blocks deep (then it can never reorg back).")
                    line += ", DIFFERENT CHAIN"
            except Exception as exc:  # noqa: BLE001
                problems[f"{name}:query"] = f"{name} did not answer a chain query: {exc}"
        if lag > LAG_BLOCKS:
            problems[f"{name}:lag"] = f"{name} is {lag} blocks behind the best node ({best})"
        summary.append(line)
        peer.close()

    summary.insert(0, f"local: height {local_height}, tip age {tip_age}s, best seen {best}")
    return problems, summary


# ---------------------------------------------------------------- alerting

def load_state():
    try:
        with open(STATE_FILE) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {"active": {}, "lag_seen": {}}


def save_state(state):
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(state, fh)
    os.replace(tmp, STATE_FILE)


def journal(priority: str, text: str):
    subprocess.run(["logger", "-t", "faircoin-monitor", "-p", f"daemon.{priority}", "--", text],
                   check=False)
    print(text)


def telegram(text: str):
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
    chat = os.environ.get("TELEGRAM_CHAT_ID", "")
    if not token or not chat:
        return
    data = urllib.parse.urlencode({"chat_id": chat, "text": text}).encode()
    try:
        urllib.request.urlopen(f"https://api.telegram.org/bot{token}/sendMessage", data, timeout=15)
    except Exception as exc:  # noqa: BLE001
        journal("err", f"telegram alert failed: {exc}")


def main() -> int:
    nodes = parse_nodes(NODES)
    if not nodes:
        journal("err", "NODES is empty; nothing to monitor")
        return 2

    problems, summary = run_checks(nodes)
    state = load_state()
    now = int(time.time())

    # Lag must persist across two runs before it counts (propagation is not an outage).
    lag_keys = {k for k in problems if k.endswith(":lag")}
    confirmed = {k: v for k, v in problems.items()
                 if not k.endswith(":lag") or k in state.get("lag_seen", {})}
    state["lag_seen"] = {k: now for k in lag_keys}

    active = state.get("active", {})
    host = socket.gethostname()
    for key, text in confirmed.items():
        last = active.get(key)
        if last is None or now - last >= REMIND_SECONDS:
            journal("warning", f"PROBLEM {text}")
            telegram(f"⚠️ FairCoin [{host}] {text}")
            active[key] = now
    for key in list(active):
        if key not in confirmed:
            journal("notice", f"RECOVERED {key}")
            telegram(f"✅ FairCoin [{host}] recovered: {key}")
            del active[key]
    state["active"] = active
    save_state(state)

    for line in summary:
        print(line)
    if not confirmed:
        print("all nodes healthy")
    return 1 if confirmed else 0


if __name__ == "__main__":
    sys.exit(main())
