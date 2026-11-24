#!/usr/bin/env python3
"""Exercise the pinned ARM terminal client and durable daemon sessions on Linux."""

import errno
import fcntl
import http.server
import json
import os
from pathlib import Path
import pty
import select
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time


PROBE = "terminal-autosave-probe"
REPLY = "terminal-autosave-ok"


class Provider(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if request.get("stream"):
            chunks = [
                {"choices": [{"index": 0, "delta": {"role": "assistant", "content": REPLY},
                              "finish_reason": None}]},
                {"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]},
            ]
            body = "".join(f"data: {json.dumps(chunk)}\n\n" for chunk in chunks)
            body = (body + "data: [DONE]\n\n").encode()
            content_type = "text/event-stream"
        else:
            body = json.dumps({
                "id": "test", "object": "chat.completion", "model": "terminal-test",
                "choices": [{"index": 0, "message": {"role": "assistant", "content": REPLY},
                             "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
            }).encode()
            content_type = "application/json"
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class Rpc:
    def __init__(self, path):
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.settimeout(30)
        self.socket.connect(str(path))
        self.stream = self.socket.makefile("rwb", buffering=0)
        self.sequence = 0
        self.call("initialize", {"protocol_version": 1})

    def call(self, method, params):
        self.sequence += 1
        request = {"jsonrpc": "2.0", "id": self.sequence, "method": method, "params": params}
        self.stream.write(json.dumps(request).encode() + b"\n")
        while True:
            line = self.stream.readline()
            if not line:
                raise RuntimeError(f"Daemon disconnected during {method}")
            response = json.loads(line)
            if response.get("id") != self.sequence:
                continue
            if "error" in response:
                raise RuntimeError(f"{method}: {response['error']}")
            return response["result"]

    def close(self):
        self.stream.close()
        self.socket.close()


def wait_for(predicate, description):
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.2)
    raise RuntimeError(f"Timed out: {description}")


def stop(process):
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            raise RuntimeError("Test process did not stop gracefully")


def drain_terminal(master, stopped, screen):
    while not stopped.is_set():
        if not select.select([master], [], [], 0.1)[0]:
            continue
        try:
            output = os.read(master, 65536)
            if not output:
                return
            screen.extend(output)
            if b"\x1b[6n" in output:
                os.write(master, b"\x1b[1;1R")
            if b"\x1b[c" in output:
                os.write(master, b"\x1b[?1;2c")
            if b"\x1b[?u" in output:
                os.write(master, b"\x1b[?0u")
        except OSError as error:
            if error.errno == errno.EIO:
                return
            raise


def main():
    binary, terminal, state = map(Path, sys.argv[1:])
    with tempfile.TemporaryDirectory(prefix="terminal-", dir=state) as directory:
        root = Path(directory)
        config = root / "config"
        home = root / "home"
        home.mkdir()
        env = dict(os.environ, HOME=str(home), TERM="xterm-256color")
        for key in ("ZEROCLAW_SOCKET", "ZEROCLAW_CONFIG_DIR"):
            env.pop(key, None)
        qemu = ["qemu-arm", "-cpu", "cortex-a7"]
        command = qemu + [str(binary), "--config-dir", str(config)]
        provider = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
        serving = threading.Thread(target=provider.serve_forever, daemon=True)
        serving.start()
        daemon = client = rpc = None
        master = slave = None
        draining = None
        stopped = threading.Event()
        screen = bytearray()
        try:
            def configure(*args):
                subprocess.run(command + ["config", *args], env=env, check=True,
                               stdout=subprocess.DEVNULL, timeout=60)

            configure("init", "providers.models.openai.terminal")
            configure("init", "risk_profiles.terminal")
            configure("init", "agents.terminal_test")
            settings = {
                "providers.models.openai.terminal.uri":
                    f"http://127.0.0.1:{provider.server_port}/v1/chat/completions",
                "providers.models.openai.terminal.model": "terminal-test",
                "providers.models.openai.terminal.api_key": "test-not-a-real-api-key",
                "agents.terminal_test.model_provider": "openai.terminal",
                "agents.terminal_test.risk_profile": "terminal",
            }
            for key, value in settings.items():
                configure("set", "--no-interactive", key, value)
            endpoint = config / "data" / "daemon.sock"
            with (root / "daemon.log").open("w+") as log:
                def start_daemon():
                    process = subprocess.Popen(
                        command + ["daemon", "--host", "127.0.0.1", "--port", "0"],
                        env=env, stdout=log, stderr=log)
                    return process

                def ready():
                    if daemon.poll() is not None:
                        log.seek(0)
                        errors = [line for line in log if "ERROR" in line or "Error:" in line]
                        raise RuntimeError("Daemon exited during startup: " + "".join(errors[-5:]))
                    if not endpoint.exists():
                        return False
                    with socket.socket(socket.AF_UNIX) as probe:
                        try:
                            probe.connect(str(endpoint))
                        except (ConnectionRefusedError, FileNotFoundError):
                            return False
                    return True

                daemon = start_daemon()
                wait_for(ready, "local daemon socket")
                rpc = Rpc(endpoint)
                master, slave = pty.openpty()
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
                client = subprocess.Popen(
                    qemu + [str(terminal), "--config-dir", str(config)],
                    env=env, cwd=root, stdin=slave, stdout=slave, stderr=slave)
                draining = threading.Thread(target=drain_terminal, args=(master, stopped, screen),
                                            daemon=True)
                draining.start()

                def connected():
                    if client.poll() is not None:
                        raise RuntimeError(f"ZeroCode exited before connecting: {client.returncode}")
                    return len(rpc.call("tui/list", {})["tuis"]) >= 2

                wait_for(connected, "real ARM ZeroCode attached to the existing daemon")
                wait_for(lambda: b"\x1b[?1049h" in screen, "interactive terminal UI")
                params = {"agent_alias": "terminal_test", "session_id": "terminal-save-test",
                          "chat_mode": "chat"}
                rpc.call("session/new", params)
                rpc.call("session/prompt", {"session_id": params["session_id"], "prompt": PROBE})

                def saved():
                    transcript = rpc.call("session/messages", {"session_id": params["session_id"]})
                    encoded = json.dumps(transcript)
                    return PROBE in encoded and REPLY in encoded

                wait_for(saved, "automatic saved user and assistant messages")
                assert client.poll() is None, "Terminal client unexpectedly exited"
                stop(client)
                rpc.close()
                rpc = None
                stop(daemon)
                daemon = start_daemon()
                wait_for(ready, "restarted daemon socket")
                rpc = Rpc(endpoint)
                assert params["session_id"] in json.dumps(rpc.call("session/list", {}))
                rpc.call("session/new", params)
                assert saved(), "Saved chat was not restored after daemon restart"
                print("Real ARM ZeroCode IPC connection and automatic chat save/restore passed")
        finally:
            if rpc is not None:
                rpc.close()
            try:
                stop(client)
            finally:
                stop(daemon)
                stopped.set()
                if draining is not None:
                    draining.join(timeout=2)
                if master is not None:
                    os.close(master)
                if slave is not None:
                    os.close(slave)
                provider.shutdown()
                provider.server_close()
                serving.join(timeout=2)


if __name__ == "__main__":
    main()
