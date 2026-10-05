# The Bija benchmark's images: Python, uv, and the skeleton's development dependencies (pytest,
# coverage) and build backend (hatchling) in uv's cache, so both the agent and the grader run the
# suite without network. The project environment lives in /tmp, outside the workspace, so it is
# never snapshotted. The grader image adds grade.py; the reference programs are in neither image,
# but are the grader's trusted input.
#
#   docker build --platform linux/amd64 --target agent -t alaya-bija-agent benchmarks/bija
#   docker build --platform linux/amd64 --target grader -t alaya-bija-grader benchmarks/bija

# The amd64 uv/Python image is pinned by its platform-specific manifest, the one Vero's image
# starts from (use Docker emulation on an ARM host); the suite's dependencies are pinned by the
# skeleton's uv.lock.
FROM ghcr.io/astral-sh/uv:0.12.7-python3.12-trixie-slim@sha256:80ffbb04bb8dfa9bfab133b36f7d35fb32216a6cb0527936328441287c26da55 AS agent

ENV UV_CACHE_DIR=/opt/uv-cache \
    UV_PROJECT_ENVIRONMENT=/tmp/venv \
    UV_LINK_MODE=copy \
    UV_OFFLINE=1

COPY skeleton/pyproject.toml skeleton/uv.lock skeleton/README.md /tmp/seed/
RUN cd /tmp/seed \
 && mkdir -p src/bija && touch src/bija/__init__.py \
 && UV_OFFLINE=0 uv sync --frozen \
 && rm -rf /tmp/seed /tmp/venv \
 && chmod -R a+rwX /opt/uv-cache

FROM agent AS grader
COPY grade.py /opt/alaya-bija/grade.py
