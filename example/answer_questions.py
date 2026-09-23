#!/usr/bin/env python3
"""Serve Alaya's waiting questions on a local browser page (Python 3.10+).

This only records replies. Resume the resulting states separately with Alaya.
"""

from __future__ import annotations

import argparse
import hmac
import json
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Iterator, Sequence
from urllib.parse import parse_qs, urlsplit


STATE_HASH = re.compile(r"[0-9a-f]{64}\Z")
MAX_BODY_BYTES = 1024 * 1024
CLI_TIMEOUT_SECONDS = 30
EVENT_POLL_SECONDS = 1
EVENT_HEARTBEAT_SECONDS = 5


class ApiError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status


class QuestionApplication:
    def __init__(self, command: Sequence[str], data: Path, template: Path):
        self.command = tuple(command)
        self.data = str(data.resolve())
        self.token = secrets.token_urlsafe(32)
        self.page = template.read_text(encoding="utf-8").replace(
            "__ALAYA_TOKEN__", self.token
        ).encode("utf-8")
        self.lock = threading.Lock()
        # One shared CLI poller, regardless of the number of listening tabs.
        # Keep its notification lock separate so a slow CLI cannot block heartbeats.
        self.events_changed = threading.Condition()
        self.events_stopped = threading.Event()
        self.events_refresh = threading.Event()
        self.events_thread: threading.Thread | None = None
        self.events_subscribers = 0
        self.events_revision = 0
        self.events_message: bytes | None = None

    def _run(self, verb: str, *args: str) -> str:
        if verb != "waiting":
            # Answers and snapshot paths such as "--data" are positional text.
            argv = [*self.command, verb, "--data", self.data, "--", *args]
        else:
            argv = [*self.command, verb, *args, "--data", self.data]
        try:
            result = subprocess.run(
                argv,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=CLI_TIMEOUT_SECONDS,
                check=False,
                shell=False,
            )
        except subprocess.TimeoutExpired as error:
            raise ApiError(502, "Alaya timed out. The question list will update automatically.") from error
        except OSError as error:
            raise ApiError(502, f"Could not run Alaya: {error}") from error
        if result.returncode:
            detail = (result.stderr or result.stdout).strip()[:2000]
            status = 400 if verb != "waiting" and result.returncode == 1 else 502
            raise ApiError(status, detail or f"Alaya exited with code {result.returncode}.")
        return result.stdout

    def _waiting(self) -> list[dict]:
        questions = []
        # JSON may contain literal Unicode line/paragraph separators in strings.
        # Only an actual LF terminates a record emitted by `waiting --json`.
        for line in self._run("waiting", "--json").split("\n"):
            if not line.strip():
                continue
            try:
                question = json.loads(line)
            except json.JSONDecodeError as error:
                raise ApiError(502, "Alaya returned invalid question JSON.") from error
            if (
                not isinstance(question, dict)
                or not isinstance(question.get("state"), str)
                or not STATE_HASH.fullmatch(question["state"])
                or not isinstance(question.get("question"), str)
                or question.get("question_type") not in
                ("yes_no", "single_choice", "open_ended")
                or not isinstance(question.get("options"), list)
                or not all(isinstance(option, str) for option in question["options"])
            ):
                raise ApiError(502, "Alaya returned an invalid question record.")
            questions.append(question)
        return questions

    def questions(self) -> list[dict]:
        with self.lock:
            return self._waiting()

    def _publish(self, event: str, value: dict) -> None:
        message = f"event: {event}\ndata: {json.dumps(value)}\n\n".encode("utf-8")
        with self.events_changed:
            if message != self.events_message:
                self.events_message = message
                self.events_revision += 1
                self.events_changed.notify_all()

    def _monitor_questions(self) -> None:
        while not self.events_stopped.is_set():
            with self.events_changed:
                self.events_changed.wait_for(
                    lambda: self.events_stopped.is_set() or self.events_subscribers > 0
                )
            if self.events_stopped.is_set():
                return
            # Publication is serialized with reply writes, so a poll started
            # before a reply cannot publish an old snapshot after that reply.
            with self.lock:
                if self.events_stopped.is_set():
                    return
                try:
                    self._publish("questions", {"questions": self._waiting()})
                except ApiError as error:
                    self._publish("unavailable", {"error": str(error)})
            self.events_refresh.wait(EVENT_POLL_SECONDS)
            self.events_refresh.clear()

    def events(self) -> Iterator[bytes]:
        with self.events_changed:
            if self.events_stopped.is_set():
                return
            if self.events_subscribers == 0:
                # After an idle period, obtain a fresh initial snapshot.
                self.events_message = None
            self.events_subscribers += 1
            if self.events_thread is None:
                self.events_thread = threading.Thread(
                    target=self._monitor_questions, name="alaya-question-events", daemon=True
                )
                self.events_thread.start()
            self.events_changed.notify_all()
            self.events_refresh.set()
        revision = -1
        try:
            while not self.events_stopped.is_set():
                with self.events_changed:
                    self.events_changed.wait_for(
                        lambda: self.events_stopped.is_set() or (
                            self.events_message is not None and self.events_revision != revision
                        ), timeout=EVENT_HEARTBEAT_SECONDS,
                    )
                    if self.events_stopped.is_set():
                        return
                    if self.events_message is not None and self.events_revision != revision:
                        revision = self.events_revision
                        message = self.events_message
                    else:
                        message = b": keepalive\n\n"
                yield message
        finally:
            with self.events_changed:
                self.events_subscribers -= 1
                self.events_changed.notify_all()
            self.events_refresh.set()

    def stop_events(self) -> None:
        self.events_stopped.set()
        self.events_refresh.set()
        with self.events_changed:
            self.events_changed.notify_all()
        if self.events_thread is not None:
            self.events_thread.join(timeout=CLI_TIMEOUT_SECONDS + 1)

    def inspect(self, verb: str, state: str, path: str | None = None) -> dict:
        args = (state,) if path is None else (state, path)
        try:
            value = json.loads(self._run(verb, *args))
        except json.JSONDecodeError as error:
            raise ApiError(502, "Alaya returned invalid context JSON.") from error
        if (
            not isinstance(value, dict) or value.get("state") != state
            or not isinstance(value.get("workspace"), str)
            or not STATE_HASH.fullmatch(value["workspace"])
            or (path is not None and value.get("path") != path)
        ):
            raise ApiError(502, "Alaya returned context for an unexpected state or path.")
        return value

    def reply(self, state: str, answer: str | None) -> str:
        # Serialize the fresh waiting check and write across browser tabs.
        # Alaya's direct CLI still permits intentional reply forks.
        with self.lock:
            waiting = self._waiting()
            if not any(question["state"] == state for question in waiting):
                self._publish("questions", {"questions": waiting})
                raise ApiError(409, "This question is no longer waiting. The list updates automatically.")
            reply = (self._run("reply-unavailable", state) if answer is None
                     else self._run("reply", state, answer)).strip()
            if not STATE_HASH.fullmatch(reply):
                self.events_refresh.set()
                raise ApiError(502, "Alaya returned an invalid reply state. The list updates automatically.")
            self._publish("questions", {"questions": [q for q in waiting if q["state"] != state]})
            self.events_refresh.set()
            return reply


class QuestionServer(ThreadingHTTPServer):
    def __init__(self, application: QuestionApplication, port: int = 0):
        self.application = application
        super().__init__(("127.0.0.1", port), QuestionHandler)
        self.authority = f"127.0.0.1:{self.server_port}"
        self.origin = f"http://{self.authority}"

    def shutdown(self) -> None:
        self.application.stop_events()
        super().shutdown()

    def server_close(self) -> None:
        self.application.stop_events()
        super().server_close()


class QuestionHandler(BaseHTTPRequestHandler):
    server: QuestionServer

    def setup(self) -> None:
        super().setup()
        self.connection.settimeout(10)

    def log_message(self, format: str, *args: object) -> None:
        # Answers and tokens should not enter the request log.
        pass

    def _send(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
            "connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
        )
        self.end_headers()
        self.wfile.write(body)

    def _json(self, status: int, value: dict) -> None:
        self._send(status, json.dumps(value).encode("utf-8"), "application/json; charset=utf-8")

    def _events(self) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        stream = self.server.application.events()
        try:
            for message in stream:
                self.wfile.write(message)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass
        finally:
            stream.close()

    def _authorize(self, require_token: bool = True) -> None:
        if self.headers.get_all("Host", []) != [self.server.authority]:
            raise ApiError(403, "Invalid local host.")
        origins = self.headers.get_all("Origin", [])
        if origins and origins != [self.server.origin]:
            raise ApiError(403, "Cross-origin requests are not allowed.")
        if self.headers.get("Sec-Fetch-Site", "none") not in ("none", "same-origin"):
            raise ApiError(403, "Cross-origin requests are not allowed.")
        if require_token:
            tokens = self.headers.get_all("X-Alaya-Token", [])
            if len(tokens) != 1 or not tokens[0].isascii() or not hmac.compare_digest(
                tokens[0], self.server.application.token
            ):
                raise ApiError(403, "Invalid page token. Reload the page.")

    def do_GET(self) -> None:
        try:
            self._authorize(require_token=self.path != "/")
            url = urlsplit(self.path)
            if self.path == "/":
                self._send(200, self.server.application.page, "text/html; charset=utf-8")
            elif self.path == "/api/questions":
                self._json(200, {"questions": self.server.application.questions()})
            elif self.path == "/api/events":
                self._events()
            elif url.path in ("/api/context", "/api/files", "/api/file"):
                try:
                    query = parse_qs(url.query, keep_blank_values=True, strict_parsing=True,
                                     max_num_fields=2, errors="strict")
                except (ValueError, UnicodeDecodeError) as error:
                    raise ApiError(400, "Invalid context query.") from error
                expected = {"state"} if url.path == "/api/context" else {"state", "path"}
                if set(query) != expected or any(len(values) != 1 for values in query.values()):
                    raise ApiError(400, "Expected one question state and, for files, one path.")
                state = query["state"][0]
                if not STATE_HASH.fullmatch(state):
                    raise ApiError(400, "Invalid question state hash.")
                path = query["path"][0] if "path" in query else None
                if path is not None and ("\0" in path or len(path) > 4096):
                    raise ApiError(400, "Invalid snapshot path.")
                verb = {"/api/context": "question-context", "/api/files": "question-files",
                        "/api/file": "question-file"}[url.path]
                self._json(200, self.server.application.inspect(verb, state, path))
            else:
                raise ApiError(404, "Not found.")
        except ApiError as error:
            self._json(error.status, {"error": str(error)})

    def _read_reply(self) -> tuple[str, str | None]:
        if self.headers.get("Content-Type", "").split(";", 1)[0].strip() != "application/json":
            raise ApiError(415, "Use application/json.")
        lengths = self.headers.get_all("Content-Length", [])
        if self.headers.get("Transfer-Encoding") or len(lengths) != 1:
            raise ApiError(400, "A single Content-Length is required.")
        try:
            length = int(lengths[0])
        except ValueError as error:
            raise ApiError(400, "Invalid Content-Length.") from error
        if length < 0:
            raise ApiError(400, "Invalid Content-Length.")
        if length > MAX_BODY_BYTES:
            raise ApiError(413, "The answer is too large.")
        try:
            raw = self.rfile.read(length)
            if len(raw) != length:
                raise ApiError(400, "Incomplete JSON body.")
            value = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError, RecursionError) as error:
            raise ApiError(400, "Invalid JSON body.") from error
        if not isinstance(value, dict) or set(value) not in ({"state", "answer"}, {"state", "status"}):
            raise ApiError(400, "Expected state and answer, or state and unavailable status.")
        state = value["state"]
        if not isinstance(state, str) or not STATE_HASH.fullmatch(state):
            raise ApiError(400, "Invalid question state hash.")
        if "status" in value:
            if value["status"] != "unavailable":
                raise ApiError(400, "The only reply status is unavailable.")
            return state, None
        answer = value["answer"]
        if not isinstance(answer, str) or "\0" in answer:
            raise ApiError(400, "The answer must be a string without NUL characters.")
        try:
            answer.encode("utf-8")
        except UnicodeEncodeError as error:
            raise ApiError(400, "The answer must contain valid Unicode.") from error
        return state, answer

    def do_POST(self) -> None:
        try:
            self._authorize()
            if self.path != "/api/reply":
                raise ApiError(404, "Not found.")
            state, answer = self._read_reply()
            self._json(200, {"reply": self.server.application.reply(state, answer)})
        except ApiError as error:
            self._json(error.status, {"error": str(error)})

    def do_OPTIONS(self) -> None:
        self._json(403, {"error": "Cross-origin requests are not allowed."})


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--alaya", required=True, help="Alaya executable (use WSL/Linux)")
    parser.add_argument("--data", type=Path, required=True, help="Alaya data directory")
    parser.add_argument("--port", type=int, default=8765,
                        help="Local port (default: 8765); 0 chooses a temporary free port")
    args = parser.parse_args()
    if not 0 <= args.port <= 65535:
        parser.error("--port must be between 0 and 65535")
    executable = shutil.which(args.alaya)
    if executable is None:
        parser.error("--alaya must name an existing executable")
    if not args.data.is_dir():
        parser.error("--data must name an existing Alaya data directory")
    try:
        application = QuestionApplication(
            [executable], args.data, Path(__file__).with_suffix(".html")
        )
        with QuestionServer(application, args.port) as server:
            print(f"Answer questions at {server.origin}/", flush=True)
            print("Replies are saved; resume their states separately. Ctrl+C stops this page.", flush=True)
            try:
                server.serve_forever()
            except KeyboardInterrupt:
                pass
    except OSError as error:
        parser.exit(1, f"Could not start the question page: {error}\n")


if __name__ == "__main__":
    main()
