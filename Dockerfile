# Stage 1: Builder
#
# Pinned to BUILDPLATFORM and cross-compiled, NOT emulated. Without the
# --platform pin, buildx rebuilds this stage once per target platform and runs
# rustc under QEMU for the ARM legs, where compiling 300+ crates is roughly an
# order of magnitude slower -- it turns a 3-4 minute build into a 30+ minute one.
# Cross-compiling keeps every leg running at native x86-64 speed.
FROM --platform=$BUILDPLATFORM rust:1-slim AS builder

ENV DEBIAN_FRONTEND=noninteractive

WORKDIR /usr/src/app

# TARGETARCH/BUILDARCH are injected automatically by buildx.
ARG TARGETARCH
ARG BUILDARCH

# Cross toolchain plus the *target's* OpenSSL headers. openssl-sys (pulled in by
# reqwest -> native-tls) links against libssl, and rusqlite's `bundled` feature
# compiles sqlite3.c, so both a cross gcc and target-arch dev headers are needed.
# Debian serves every architecture from the same mirrors, so plain multiarch works.
RUN set -eu; \
    case "${TARGETARCH}" in \
        amd64) DEB_ARCH=amd64; CROSS_PKG="" ;; \
        arm64) DEB_ARCH=arm64; CROSS_PKG="gcc-aarch64-linux-gnu" ;; \
        arm)   DEB_ARCH=armhf; CROSS_PKG="gcc-arm-linux-gnueabihf" ;; \
        *) echo "Unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    if [ "${DEB_ARCH}" != "$(dpkg --print-architecture)" ]; then \
        dpkg --add-architecture "${DEB_ARCH}"; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        pkg-config build-essential ffmpeg ${CROSS_PKG} \
        "libssl-dev:${DEB_ARCH}" "libc6-dev:${DEB_ARCH}"; \
    rm -rf /var/lib/apt/lists/*

COPY Cargo.toml Cargo.lock ./

RUN mkdir src && echo "fn main(){}" > src/main.rs

COPY src ./src
COPY include ./include
COPY tests ./tests

# The test suite only runs on the native leg. A cross-built binary cannot execute
# on the builder, and the same tests already run natively on the amd64 leg.
RUN set -eu; \
    case "${TARGETARCH}" in \
        amd64) RUST_TARGET=x86_64-unknown-linux-gnu ;; \
        arm64) RUST_TARGET=aarch64-unknown-linux-gnu; \
               export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc; \
               export CC_aarch64_unknown_linux_gnu=aarch64-linux-gnu-gcc; \
               export PKG_CONFIG_PATH=/usr/lib/aarch64-linux-gnu/pkgconfig ;; \
        arm)   RUST_TARGET=armv7-unknown-linux-gnueabihf; \
               export CARGO_TARGET_ARMV7_UNKNOWN_LINUX_GNUEABIHF_LINKER=arm-linux-gnueabihf-gcc; \
               export CC_armv7_unknown_linux_gnueabihf=arm-linux-gnueabihf-gcc; \
               export PKG_CONFIG_PATH=/usr/lib/arm-linux-gnueabihf/pkgconfig ;; \
    esac; \
    export PKG_CONFIG_ALLOW_CROSS=1; \
    export PKG_CONFIG_SYSROOT_DIR=/; \
    rustup target add "${RUST_TARGET}"; \
    touch -c src/main.rs; \
    if [ "${TARGETARCH}" = "${BUILDARCH}" ]; then \
        cargo test --release --locked; \
    else \
        echo "Skipping cargo test (cross build: build=${BUILDARCH} target=${TARGETARCH})"; \
    fi; \
    cargo build --release --locked --target "${RUST_TARGET}"; \
    cp "target/${RUST_TARGET}/release/eas_listener" /usr/local/bin/eas_listener

# ----------------------------------------------------------------------------------------- #

# Stage 2: Runner
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV XDG_RUNTIME_DIR=/run/user/1000

# VARIANT=full -> Piper + espeak-ng, plus Speechify Tom on every arch we build
#                 for (amd64, arm64, armv7; see the SPFY_ASSET_* args below).
# VARIANT=lite -> Piper + espeak-ng only, on every arch. DEPRECATED; the `-lite`
#                 tag is still published so existing pulls keep working. See README.
ARG VARIANT=full
ARG TARGETARCH

ENV EAS_IMAGE_VARIANT=${VARIANT}

# Speechify Tom is enabled per-architecture by the SPFY_ASSET_SHA256_* args
# below. A non-empty checksum means "upstream publishes a spfy build for this
# arch, install it"; an empty one means "skip it here, and let the entrypoint
# fall back to Piper at runtime". As of the 2026.07.22 release every Linux arch
# we build for has a native asset, so all three are filled in. The legacy 32-bit
# "x86" asset still exists but is deliberately unused: selecting it is what
# would drag i386 multiarch back into the image.
#
# These checksums pin exact bytes. If a release is ever re-cut under the same
# tag, they must be refreshed or the build fails closed at `sha256sum -c`.
ARG SPFY_VERSION=2026.08.31
ARG SPFY_ASSET_SLUG_AMD64="x86_64"
ARG SPFY_ASSET_SHA256_AMD64="c75db941314af3a8163095d63eddca0479076af0eedd7b29f0a015d73141db69"
ARG SPFY_ASSET_SLUG_ARM64="arm64"
ARG SPFY_ASSET_SHA256_ARM64="7ccdd7380459b67b54ce11727c51dc5713834faab5b6fc0bfc7be4b51a5756e6"
ARG SPFY_ASSET_SLUG_ARM="armv7"
ARG SPFY_ASSET_SHA256_ARM="a2f7008f8db16ba185d420e46da36d885fe97a0007f91982a5c5f9b43b6c3a2f"

ARG PIPER_VERSION=2023.11.14-2
ARG PIPER_VOICE=en_US-lessac-medium

# Port the bundled Icecast server listens on / is exposed for the 24/7 alert
# stream. Keep in sync with ICECAST_ALERT_PORT in config.json and .env.
ARG ICECAST_ALERT_PORT=8000

# libssl3t64, not libssl3: Debian's 64-bit time_t transition renamed the OpenSSL
# 3 runtime, and on trixie `libssl3` has no installation candidate on any of our
# architectures. It only resolved on amd64/arm64 by virtual-package indirection,
# and on armhf it does not resolve at all -- so name the real package directly.
RUN mkdir -p /run/user/1000 && chown 1000:1000 /run/user/1000 \
    && mkdir -p /var/lib/apt/lists/partial \
    && apt-get update && apt-get install -y --no-install-recommends \
       libssl3t64 ca-certificates bash nginx jq ffmpeg curl apprise espeak-ng \
       php-fpm php-cli php-sqlite3 icecast2 \
    && rm -rf /var/lib/apt/lists/* \
    && chsh -s /bin/bash \
    && mkdir -p /data /var/www/html /app /app/piper

# Piper TTS binary + voice model. Ships on every architecture and every variant,
# so there is always a working engine even where Speechify cannot be installed.
RUN set -eu; \
    case "${TARGETARCH}" in \
        amd64) PIPER_ARCH=x86_64 ;; \
        arm64) PIPER_ARCH=aarch64 ;; \
        arm)   PIPER_ARCH=armv7l ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fL --retry 5 --retry-delay 2 -o /tmp/piper.tar.gz \
        "https://github.com/rhasspy/piper/releases/download/${PIPER_VERSION}/piper_linux_${PIPER_ARCH}.tar.gz"; \
    tar xzf /tmp/piper.tar.gz -C /app/piper --strip-components=1; \
    rm /tmp/piper.tar.gz; \
    curl -fL --retry 5 --retry-delay 2 -o "/app/piper/${PIPER_VOICE}.onnx" \
        "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/en/en_US/lessac/medium/en_US-lessac-medium.onnx"; \
    curl -fL --retry 5 --retry-delay 2 -o "/app/piper/${PIPER_VOICE}.onnx.json" \
        "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json"; \
    ln -sf /app/piper/piper /usr/local/bin/piper

# Speechify Tom, for VARIANT=full on any arch that has a published spfy build.
# Skipped (not failed) everywhere else, so the same Dockerfile keeps producing a
# valid image on architectures spfy has not reached yet and for the lite tag.
# The i386 branch only fires if someone points an arch at the legacy 32-bit
# "x86" asset; the native x86_64 and arm64 builds need no foreign architecture.
RUN set -eu; \
    case "${TARGETARCH}" in \
        amd64) SPFY_SLUG="${SPFY_ASSET_SLUG_AMD64}"; SPFY_SHA256="${SPFY_ASSET_SHA256_AMD64}" ;; \
        arm64) SPFY_SLUG="${SPFY_ASSET_SLUG_ARM64}"; SPFY_SHA256="${SPFY_ASSET_SHA256_ARM64}" ;; \
        arm)   SPFY_SLUG="${SPFY_ASSET_SLUG_ARM}";   SPFY_SHA256="${SPFY_ASSET_SHA256_ARM}" ;; \
        *)     SPFY_SLUG=""; SPFY_SHA256="" ;; \
    esac; \
    if [ "${VARIANT}" != "full" ]; then \
        echo "Skipping Speechify Tom: VARIANT=${VARIANT}. Piper and espeak-ng remain available."; \
        exit 0; \
    fi; \
    if [ -z "${SPFY_SHA256}" ]; then \
        echo "Skipping Speechify Tom: no spfy build is published for ${TARGETARCH} yet. Piper and espeak-ng remain available."; \
        exit 0; \
    fi; \
    if [ "${SPFY_SLUG}" = "x86" ]; then \
        dpkg --add-architecture i386; \
        apt-get update; \
        apt-get install -y --no-install-recommends libc6:i386; \
        rm -rf /var/lib/apt/lists/*; \
    fi; \
    ASSET_DIR="spfy-linux-${SPFY_SLUG}-${SPFY_VERSION}"; \
    ASSET_NAME="${ASSET_DIR}.tar.gz"; \
    TEMP_DIR="/tmp/spfy"; \
    curl -fL --retry 5 --retry-delay 2 -o "/tmp/${ASSET_NAME}" \
        "https://github.com/wagwan-piffting-blud/Speechify/releases/download/${SPFY_VERSION}/${ASSET_NAME}"; \
    echo "${SPFY_SHA256}  /tmp/${ASSET_NAME}" | sha256sum -c -; \
    mkdir -p "${TEMP_DIR}" "/app/voices/tom"; \
    tar -xzvf "/tmp/${ASSET_NAME}" -C "${TEMP_DIR}" --strip-components=1; \
    mv "${TEMP_DIR}/bin/spfy_synth" /usr/local/bin/spfy_synth; \
    chmod +x /usr/local/bin/spfy_synth; \
    mv "${TEMP_DIR}/en-US/tom" /app/voices; \
    chmod -R 755 /app/voices; \
    rm -rf "/tmp/${ASSET_NAME}" "${TEMP_DIR}";

RUN userdel icecast2 && useradd -m -s /bin/bash icecast2 && chown -R icecast2:icecast2 /etc/icecast2 /var/log/icecast2

COPY --from=builder /usr/local/bin/eas_listener /usr/local/bin/eas_listener
COPY ./docker_entrypoint.sh /docker_entrypoint.sh
COPY ./nginx.conf /etc/nginx/sites-available/default
COPY ./web_server/ /var/www/html
COPY ./Cargo.toml /app/Cargo.toml

WORKDIR /app

RUN chmod +x /docker_entrypoint.sh && chmod -R 777 /data /var/www/html

HEALTHCHECK --interval=10s --timeout=10s --retries=3 --start-period=5s CMD curl --fail http://localhost:${MONITORING_BIND_PORT}/api/health || exit 1

EXPOSE 80
EXPOSE ${MONITORING_BIND_PORT}
EXPOSE ${ICECAST_ALERT_PORT}

ENTRYPOINT ["/docker_entrypoint.sh"]
