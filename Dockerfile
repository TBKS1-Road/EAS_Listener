# Stage 1: Builder
#
# Pinned to BUILDPLATFORM and cross-compiled, NOT emulated. Without the
# --platform pin, buildx rebuilds this stage once per target platform and runs
# rustc under QEMU for the ARM legs, where compiling 300+ crates is roughly an
# order of magnitude slower -- it turns a 3-4 minute build into a 30+ minute one.
# Cross-compiling keeps every leg running at native speed.
#
# When the CI runner's own architecture already matches the target (the arm64
# leg runs on a native arm64 runner), TARGETARCH == BUILDARCH and no cross
# toolchain is installed or referenced at all.
FROM --platform=$BUILDPLATFORM rust:1-slim AS builder

ENV DEBIAN_FRONTEND=noninteractive
# Incremental artifacts are worthless here -- each layer starts from the cached
# image, never from a previous incremental run -- and they inflate the exported
# build cache substantially.
ENV CARGO_INCREMENTAL=0
ENV CARGO_NET_RETRY=5
ENV CARGO_TERM_COLOR=never

WORKDIR /usr/src/app

# TARGETARCH/BUILDARCH are injected automatically by buildx.
ARG TARGETARCH
ARG BUILDARCH

# Cross toolchain plus the *target's* OpenSSL headers. openssl-sys (pulled in by
# reqwest -> native-tls) links against libssl, and rusqlite's `bundled` feature
# compiles sqlite3.c, so both a cross gcc and target-arch dev headers are needed.
# Debian serves every architecture from the same mirrors, so plain multiarch works.
#
# ffmpeg is deliberately absent: nothing links against it, and nothing in the
# test suite shells out to it. It is only ever invoked at runtime (see
# `Command::new("ffmpeg")` in src/cap.rs), so it belongs in the runner stage
# alone, where it already is. Installing it here dragged ~200 extra packages
# into every one of the three builder legs.
RUN set -eu; \
    case "${TARGETARCH}" in \
        amd64) DEB_ARCH=amd64; CROSS_PKG="gcc-x86-64-linux-gnu" ;; \
        arm64) DEB_ARCH=arm64; CROSS_PKG="gcc-aarch64-linux-gnu" ;; \
        arm)   DEB_ARCH=armhf; CROSS_PKG="gcc-arm-linux-gnueabihf" ;; \
        *) echo "Unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    if [ "${TARGETARCH}" = "${BUILDARCH}" ]; then CROSS_PKG=""; fi; \
    if [ "${DEB_ARCH}" != "$(dpkg --print-architecture)" ]; then \
        dpkg --add-architecture "${DEB_ARCH}"; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        pkg-config build-essential ${CROSS_PKG} \
        "libssl-dev:${DEB_ARCH}" "libc6-dev:${DEB_ARCH}"; \
    rm -rf /var/lib/apt/lists/*

# The target triple and its cross-compilation environment are resolved once and
# written to a file, so the dependency build and the application build below
# stay byte-identical without duplicating the case statement. The linker/CC
# overrides are emitted only when actually cross-compiling; pointing cargo at
# `aarch64-linux-gnu-gcc` on a native arm64 builder would just fail.
RUN set -eu; \
    case "${TARGETARCH}" in \
        amd64) RUST_TARGET=x86_64-unknown-linux-gnu;      GNU_TRIPLE=x86_64-linux-gnu ;; \
        arm64) RUST_TARGET=aarch64-unknown-linux-gnu;     GNU_TRIPLE=aarch64-linux-gnu ;; \
        arm)   RUST_TARGET=armv7-unknown-linux-gnueabihf; GNU_TRIPLE=arm-linux-gnueabihf ;; \
        *) echo "Unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    { \
        echo "export RUST_TARGET=${RUST_TARGET}"; \
        if [ "${TARGETARCH}" != "${BUILDARCH}" ]; then \
            echo "export CARGO_TARGET_$(echo "${RUST_TARGET}" | tr 'a-z-' 'A-Z_')_LINKER=${GNU_TRIPLE}-gcc"; \
            echo "export CC_$(echo "${RUST_TARGET}" | tr '-' '_')=${GNU_TRIPLE}-gcc"; \
            echo "export PKG_CONFIG_ALLOW_CROSS=1"; \
            echo "export PKG_CONFIG_SYSROOT_DIR=/"; \
            echo "export PKG_CONFIG_PATH=/usr/lib/${GNU_TRIPLE}/pkgconfig"; \
        fi; \
    } > /etc/cross.env; \
    rustup target add "${RUST_TARGET}"

# Dependency prebuild against a stub main.rs. This layer is keyed on Cargo.toml
# and Cargo.lock alone, so editing src/ no longer recompiles symphonia's codec
# set, the bundled sqlite3.c, and 300-odd other crates -- which is what made
# every leg of this build take 11-15 minutes regardless of how small the change
# was. Previously the stub was written and then immediately clobbered by
# `COPY src ./src` before anything was ever built against it, so it bought
# nothing.
COPY Cargo.toml Cargo.lock ./
RUN set -eu; \
    . /etc/cross.env; \
    mkdir -p src; \
    echo 'fn main() {}' > src/main.rs; \
    cargo build --release --locked --target "${RUST_TARGET}"; \
    rm -rf src \
       "target/${RUST_TARGET}/release/eas_listener" \
       "target/${RUST_TARGET}/release/deps/eas_listener"*

# include/ is pulled in via include_str! and so is a genuine compile-time input.
# tests/ is not: it holds fixtures only, and the suite now runs in its own CI
# job rather than inside this stage, where it could not share a cargo cache
# across runs and added ~200s to the amd64 leg.
COPY include ./include
COPY src ./src

# The touch is not cosmetic: the layer above left a fingerprint for a stub
# main.rs in target/, and COPY carries the build context's mtimes rather than
# minting fresh ones. Bumping them guarantees cargo treats the real sources as
# dirty and actually re-links the binary the `cp` below expects to find.
RUN set -eu; \
    . /etc/cross.env; \
    find src include -type f -exec touch {} +; \
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

# Excluding man pages and package docs is not about image size here -- it is
# about build time. This apt invocation is the one part of the image that
# genuinely cannot be cross-compiled away, because dpkg has to run each
# package's maintainer scripts as the target architecture. Under QEMU the
# man-db and mandb triggers alone accounted for several minutes of the armv7
# leg. Acquire::Languages=none likewise skips downloading translation indices
# nothing in this image reads.
#
# libssl3t64, not libssl3: Debian's 64-bit time_t transition renamed the OpenSSL
# 3 runtime, and on trixie `libssl3` has no installation candidate on any of our
# architectures. It only resolved on amd64/arm64 by virtual-package indirection,
# and on armhf it does not resolve at all -- so name the real package directly.
RUN set -eu; \
    printf 'path-exclude /usr/share/man/*\npath-exclude /usr/share/doc/*\npath-include /usr/share/doc/*/copyright\n' \
        > /etc/dpkg/dpkg.cfg.d/01-nodoc; \
    printf 'Acquire::Languages "none";\n' > /etc/apt/apt.conf.d/01-no-languages; \
    mkdir -p /run/user/1000; \
    chown 1000:1000 /run/user/1000; \
    mkdir -p /var/lib/apt/lists/partial; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libssl3t64 ca-certificates bash nginx jq ffmpeg curl apprise espeak-ng \
        php-fpm php-cli php-sqlite3 icecast2; \
    rm -rf /var/lib/apt/lists/*; \
    chsh -s /bin/bash; \
    mkdir -p /data /var/www/html /app /app/piper

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
#
# tar runs without -v here: under QEMU, writing a line per extracted voice file
# to the build log was measurably slower than the extraction itself.
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
    tar -xzf "/tmp/${ASSET_NAME}" -C "${TEMP_DIR}" --strip-components=1; \
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
