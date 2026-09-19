#!/usr/bin/env python3
"""Private, opt-in capture of actual XMCP JSON bodies for controlled experiments.

Install a curl shim with `python record_model_io.py install PRIVATE_BIN`, prepend
PRIVATE_BIN to PATH, and set ALAYA_MODEL_IO_DIR for each run. The shim forwards
the exact argv to /usr/bin/curl, preserving stdout, stderr and exit status. It
never reads curl's credential configuration or response headers. Only requests
to the experiment's existing chat-completions endpoint are recorded.
"""
from __future__ import annotations

import hashlib
import json
import os
import shlex
import subprocess
import sys
import time
import uuid
from pathlib import Path

ENDPOINT = "https://llm.xmcp.ltd/chat/completions"
CURL = "/usr/bin/curl"


def option(args, flag):
    try:
        return args[args.index(flag) + 1]
    except (ValueError, IndexError):
        return None


def private_write(path, contents):
    """Fail closed if a requested capture cannot be persisted."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(contents)


def run(args, *, curl=CURL):
    directory = os.environ.get("ALAYA_MODEL_IO_DIR")
    data = option(args, "--data")
    output = option(args, "--output")
    capture = directory and ENDPOINT in args and data and data.startswith("@") and output
    if not capture:
        return subprocess.run([curl, *args], check=False).returncode
    prefix = Path(directory) / (str(time.time_ns()) + "-" + uuid.uuid4().hex)
    request = Path(data[1:]).read_bytes()
    json.loads(request)  # do not present a non-JSON upload as a recorded request
    private_write(str(prefix) + ".request.json", request)
    started = time.monotonic()
    result = subprocess.run([curl, *args], check=False)
    response_path = Path(output)
    response = response_path.read_bytes() if response_path.exists() else None
    if response is not None:
        private_write(str(prefix) + ".response.json", response)
    metadata = {"endpoint": ENDPOINT, "curl_exit_code": result.returncode,
                "seconds": time.monotonic() - started,
                "request_sha256": hashlib.sha256(request).hexdigest(),
                "response_sha256": hashlib.sha256(response).hexdigest() if response is not None else None,
                "response_present": response is not None}
    private_write(str(prefix) + ".meta.json", (json.dumps(metadata, indent=2) + "\n").encode())
    return result.returncode


def install(directory):
    directory = Path(directory).resolve()
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    target = directory / "curl"
    script = "#!/bin/sh\nexec " + shlex.join([sys.executable, str(Path(__file__).resolve())]) + ' "$@"\n'
    private_write(target, script.encode())
    target.chmod(0o700)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "install":
        install(sys.argv[2])
    else:
        sys.exit(run(sys.argv[1:]))
