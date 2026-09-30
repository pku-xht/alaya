# The Bija benchmark's image: Python, uv, and the skeleton's development dependencies (pytest,
# coverage) and build backend (hatchling) in uv's cache, so both the agent and the grader run the
# suite without network. The project environment lives in /tmp, outside the workspace, so it is
# never snapshotted.
#
#   docker build -t alaya-bija example/bija
FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

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
