FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim
WORKDIR /project
COPY . .
RUN uv sync --frozen --no-install-project 2>/dev/null || uv sync
CMD ["uv", "run", "pytest"]
