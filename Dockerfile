# syntax=docker/dockerfile:1

# ================================
# Build image
# ================================
FROM swift:6.1-noble AS build

# Install OS updates and dependencies in one layer (apt caches persisted across builds via BuildKit cache mounts)
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q dist-upgrade -y \
    && apt-get install -y --no-install-recommends \
       libjemalloc-dev \
       libldap-dev

WORKDIR /build

# Copy dependency files first for better caching
COPY ./Package.* ./
RUN --mount=type=cache,target=/build/.build,sharing=locked \
    --mount=type=cache,target=/root/.cache/org.swift.swiftpm,sharing=locked \
    swift package resolve

# Copy source code
COPY . .

# Build with build cache mount and parallel jobs
RUN --mount=type=cache,target=/build/.build,sharing=locked \
    --mount=type=cache,target=/root/.cache/org.swift.swiftpm,sharing=locked \
    swift build -c release \
        --product FynnCloudServer \
        --static-swift-stdlib \
        -j $(nproc) \
        -Xlinker -ljemalloc \
        -Xswiftc -gnone \
    && mkdir -p /staging \
    && cp ".build/release/FynnCloudServer" /staging \
    && (cp -R .build/release/*.resources /staging/ 2>/dev/null || true) \
    && (cp -R .build/release/*.bundle /staging/ 2>/dev/null || true) \
    && (cp -R .build/*/release/*.resources /staging/ 2>/dev/null || true) \
    && (cp -R .build/*/release/*.bundle /staging/ 2>/dev/null || true) \
    && ([ -d /build/Public ] && cp -R /build/Public /staging/ || true) \
    && ([ -d /build/Resources ] && cp -R /build/Resources /staging/ || true)

# ================================
# Run image
# ================================
FROM debian:trixie-slim

# Install minimal runtime dependencies (apt caches persisted across builds via BuildKit cache mounts)
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q install -y --no-install-recommends \
      libjemalloc2 \
      libldap2 \
      ca-certificates \
      libvips-tools \
      ffmpeg \
      tzdata \
    && useradd --user-group --create-home --system --skel /dev/null --home-dir /app vapor

WORKDIR /app

# Copy built executable and any staged resources from builder
COPY --from=build --chown=vapor:vapor /staging /app

# Make resources read-only
RUN chmod -R a-w ./Public ./Resources 2>/dev/null || true

# Create Storage directory with correct permissions
RUN mkdir -p /app/Storage && chown -R vapor:vapor /app/Storage

# Ensure all further commands run as the vapor user
USER vapor:vapor

# Let Docker bind to port 8080
EXPOSE 8080

# Start the Vapor service when the image is run
ENTRYPOINT ["./FynnCloudServer"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]