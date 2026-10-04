# This amd64 uv/Python image is pinned by its platform-specific manifest.  In
# addition to uv, it supplies the fixed CA bundle needed to reach Ubuntu's
# HTTPS snapshot service before Ubuntu's own ca-certificates package exists.
FROM ghcr.io/astral-sh/uv:0.12.7-python3.12-trixie-slim@sha256:80ffbb04bb8dfa9bfab133b36f7d35fb32216a6cb0527936328441287c26da55 AS uv

# Ubuntu is pinned so apt package resolution starts from a fixed filesystem.
FROM ubuntu:24.04@sha256:008173c23f95b170204355c12626cb5a965d779a7e1283b09e9cffbb1bf33ca3 AS base

ARG DEBIAN_FRONTEND=noninteractive
ARG UBUNTU_SNAPSHOT=20260923T000000Z
ARG VERO_REPOSITORY=https://github.com/sunblaze-ucb/vero.git
ARG VERO_COMMIT=0a7325df9e9e6dbc275c0ad483b3d1cbe38d9b09
ARG LEAN_TOOLCHAIN=leanprover/lean4:v4.29.1

LABEL org.opencontainers.image.source="https://github.com/msv-lab/alaya" \
      org.opencontainers.image.description="Offline MiniVero execution and grading environment" \
      io.alaya.vero.commit="${VERO_COMMIT}" \
      io.alaya.lean.toolchain="${LEAN_TOOLCHAIN}"

# The minimal Ubuntu base has no CA bundle.  Bootstrap it from the already
# pinned stage, then freeze both direct and transitive apt dependencies at one
# Ubuntu archive snapshot.  Installing ca-certificates below replaces this
# bootstrap bundle with the Ubuntu package from that same snapshot.
COPY --from=uv /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
RUN printf 'APT::Snapshot "%s";\n' "${UBUNTU_SNAPSHOT}" \
      > /etc/apt/apt.conf.d/50snapshot \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      bash \
      build-essential \
      ca-certificates \
      coreutils \
      curl \
      elan \
      git \
      python3 \
      python3-venv \
      unzip \
      xz-utils \
      zstd \
 && rm -rf /var/lib/apt/lists/*

COPY --from=uv /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/

# Put the selected Lean installation in a system path that remains readable when
# Alaya runs the container as the host uid:gid rather than as root.
ENV ELAN_HOME=/opt/elan \
    PATH="/opt/elan/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy
RUN elan toolchain install "${LEAN_TOOLCHAIN}" \
 && elan default "${LEAN_TOOLCHAIN}" \
 && lean --version \
 && lake --version

FROM base AS dependencies

# Fetch exactly the reviewed Vero revision.  Vero is installed from its lockfile;
# its Python source remains for the renderer and the grader, while its benchmark
# and reference trees are removed below so the agent cannot inspect trusted
# inputs or solutions from the execution image.
RUN git init /opt/vero \
 && git -C /opt/vero remote add origin "${VERO_REPOSITORY}" \
 && git -C /opt/vero fetch --depth 1 origin "${VERO_COMMIT}" \
 && git -C /opt/vero checkout --detach FETCH_HEAD \
 && test "$(git -C /opt/vero rev-parse HEAD)" = "${VERO_COMMIT}" \
 && cd /opt/vero \
 && uv sync --python /usr/bin/python3 --frozen --no-dev

ENV PATH="/opt/vero/.venv/bin:/opt/elan/bin:/usr/local/bin:/usr/bin:/bin"

# Seven Vero projects use the same pinned Mathlib dependency graph.  Populate a
# shared source tree once and point every project at it. Resolve from the existing
# lock; this source-fetching layer must not rewrite any dependency revision.
RUN set -eux; \
    seed=/opt/vero/benchmarks/DedekindReals; \
    projects="DedekindReals Flocq Huffman Json VerifiedIronkv ecdsa Sequences"; \
    cd "$seed"; \
    cp lake-manifest.json /tmp/vero-lake-lock.json; \
    lake resolve-deps; \
    cmp lake-manifest.json /tmp/vero-lake-lock.json; \
    for name in $projects; do \
      project="/opt/vero/benchmarks/$name"; \
      if [ "$project" != "$seed" ]; then \
        mkdir -p "$project/.lake"; \
        rm -rf "$project/.lake/packages"; \
        ln -s "$seed/.lake/packages" "$project/.lake/packages"; \
      fi; \
    done

# Download the pinned Mathlib `.olean` set with bounded retries.  Both the
# package-source layer above and successfully downloaded archives survive a
# transient Azure cache failure, so a retry neither reclones nor recompiles.
RUN --mount=type=cache,target=/root/.cache/mathlib set -eux; \
    cd /opt/vero/benchmarks/DedekindReals; \
    attempt=1; \
    until lake exe cache get; do \
      if [ "$attempt" -ge 3 ]; then \
        echo "Mathlib cache download failed after $attempt attempts" >&2; \
        exit 1; \
      fi; \
      attempt=$((attempt + 1)); \
      echo "retrying Mathlib cache download ($attempt/3)" >&2; \
      sleep 2; \
    done

# The explicit cache step fetches the complete cache for this pinned revision,
# not merely one benchmark's imports.  Refuse to publish the image unless it
# left actual compiled objects, then move the shared package tree out of the
# trusted benchmark directories.  Runtime containers have no network and only
# read this tree. Prewarming dependency targets also saves Lake hash sidecars that the
# downloaded cache can omit, so a non-root offline build never needs to create them.
RUN set -eux; \
    seed=/opt/vero/benchmarks/DedekindReals; \
    find "$seed/.lake/packages" -name '*.olean' -print -quit | grep -q .; \
    mv "$seed/.lake/packages" /opt/vero-packages; \
    ln -s /opt/vero-packages "$seed/.lake/packages"; \
    cd "$seed"; \
    lake build @mathlib/Mathlib @proofwidgets/widgetPackageLock; \
    cmp lake-manifest.json /tmp/vero-lake-lock.json; \
    find /opt/vero-packages -name '*.olean' -print -quit | grep -q .

# A rendered workspace is bind-mounted over /workspace, so package sources in
# the image do not appear there automatically.  The agent and grader targets
# carry prepare.py as /opt/alaya-vero/prepare.py: it validates the workspace
# lock against the image cohort, then creates only the missing Lake package
# symlinks.  Run it once after rendering and before `alaya new`.

# Record the actual system package and tool versions in the image.  Remove the
# trusted benchmark trees after their dependency cache has been prepared. Alaya
# mounts a snapshot of one trusted benchmark read-only for each evaluation.
RUN mkdir -p /opt/vero-image \
 && cp /opt/vero/benchmarks/DedekindReals/lake-manifest.json \
      /opt/vero-image/lake-manifest.json \
 && printf '%s\n' "${VERO_COMMIT}" > /opt/vero-image/vero-commit.txt \
 && printf '%s\n' "${LEAN_TOOLCHAIN}" > /opt/vero-image/lean-toolchain.txt \
 && lean --version > /opt/vero-image/lean-version.txt \
 && lake --version > /opt/vero-image/lake-version.txt \
 && uv --version > /opt/vero-image/uv-version.txt \
 && /opt/vero/.venv/bin/python --version > /opt/vero-image/python-version.txt \
 && dpkg-query -W -f='${binary:Package}\t${Version}\n' \
      bash build-essential ca-certificates coreutils curl elan git python3 \
      python3-venv unzip xz-utils zstd > /opt/vero-image/apt-packages.tsv \
 && for package in /opt/vero-packages/*; do \
      git config --system --add safe.directory "$package"; \
    done \
 && rm -rf /opt/vero/.git /opt/vero/benchmarks /opt/vero/reference \
 && chmod -R a+rX /opt/elan /opt/vero /opt/vero-image /opt/vero-packages \
 && rm -rf /root/.cache

# The agent image never inherits Vero's Python installation or the removed
# benchmark and reference trees.
FROM base AS agent
COPY --from=dependencies /opt/vero-packages /opt/vero-packages
COPY --from=dependencies /opt/vero-image /opt/vero-image
COPY benchmarks/vero/prepare.py /opt/alaya-vero/prepare.py
RUN for package in /opt/vero-packages/*; do git config --system --add safe.directory "$package"; done
WORKDIR /workspace
CMD ["/bin/sh"]

FROM agent AS grader
COPY --from=dependencies /opt/vero /opt/vero
COPY benchmarks/vero/patches/*.patch /opt/alaya-vero/
RUN cd /opt/vero && git apply --check /opt/alaya-vero/*.patch && git apply /opt/alaya-vero/*.patch
ENV PATH="/opt/vero/.venv/bin:/opt/elan/bin:/usr/local/bin:/usr/bin:/bin"
COPY benchmarks/vero/render.py /opt/alaya-vero/render.py
COPY benchmarks/vero/grade.py /opt/alaya-vero/grade.py
