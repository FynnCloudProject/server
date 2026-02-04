# ================================
# Build image
# ================================
FROM swift:6.1-noble AS build

# Install OS updates and dependencies in one layer
RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q dist-upgrade -y \
    && apt-get install -y libjemalloc-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Copy dependency files first for better caching
COPY ./Package.* ./
RUN swift package resolve \
        $([ -f ./Package.resolved ] && echo "--force-resolved-versions" || true)

# Copy source code
COPY . .

# Build with build cache mount and parallel jobs
RUN --mount=type=cache,target=/build/.build,sharing=locked \
    swift build -c release \
        --product FynnCloudBackend \
        --static-swift-stdlib \
        -Xlinker -ljemalloc \
        -Xswiftc -j$(nproc) \
        -Xswiftc -gnone \
    && mkdir -p /staging \
    && cp ".build/release/FynnCloudBackend" /staging \
    && ([ -d /build/Public ] && cp -R /build/Public /staging/ || true) \
    && ([ -d /build/Resources ] && cp -R /build/Resources /staging/ || true)

# ================================
# Run image
# ================================
FROM alpine:3.23

# Install minimal runtime dependencies
RUN apk add --no-cache \
    libstdc++ \
    libgcc \
    ca-certificates \
    tzdata

# Create a vapor user and group
RUN addgroup -g 1000 vapor && \
    adduser -D -u 1000 -G vapor vapor

WORKDIR /app

# Copy built executable and any staged resources from builder
COPY --from=build --chown=vapor:vapor /staging /app

# Make resources read-only
RUN chmod -R a-w ./Public ./Resources 2>/dev/null || true

# Provide configuration needed by the built-in crash reporter
#ENV SWIFT_BACKTRACE=enable=yes,sanitize=yes,threads=all,images=all,interactive=no,swift-backtrace=./swift-backtrace-static

# Ensure all further commands run as the vapor user
USER vapor:vapor

# Let Docker bind to port 8080
EXPOSE 8080

# Start the Vapor service when the image is run
ENTRYPOINT ["./FynnCloudBackend"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]