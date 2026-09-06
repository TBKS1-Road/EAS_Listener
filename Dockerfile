# Stage 1: Builder
FROM --platform=$BUILDPLATFORM rust:1-slim AS builder

ENV DEBIAN_FRONTEND=noninteractive
ENV CARGO_INCREMENTAL=0
ENV CARGO_NET_RETRY=5
ENV CARGO_TERM_COLOR=never
WORKDIR /usr/src/app
ARG TARGETARCH
ARG BUILDARCH

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

COPY Cargo.toml Cargo.lock ./
RUN set -eu; \
    . /etc/cross.env; \
    mkdir -p src; \
    echo 'fn main() {}' > src/main.rs; \
    cargo build --release --locked --target "${RUST_TARGET}"; \
    rm -rf src \
       "target/${RUST_TARGET}/release/eas_listener" \
       "target/${RUST_TARGET}/release/deps/eas_listener"*

COPY include ./include
COPY src ./src

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
ARG VARIANT=full
ARG TARGETARCH
ENV EAS_IMAGE_VARIANT=${VARIANT}
ARG SPFY_REPO=wagwan-piffting-blud/Speechify
ARG SPFY_VERSION=latest
ARG SPFY_ASSET_SLUG_AMD64="x86_64"
ARG SPFY_ASSET_SLUG_ARM64="arm64"
ARG SPFY_ASSET_SLUG_ARM="armv7"
ARG SPFY_ASSET_SHA256_AMD64=""
ARG SPFY_ASSET_SHA256_ARM64=""
ARG SPFY_ASSET_SHA256_ARM=""
ARG PIPER_VERSION=2023.11.14-2
ARG PIPER_VOICE=en_US-lessac-medium
ARG ICECAST_ALERT_PORT=8000

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
    if [ -z "${SPFY_SLUG}" ]; then \
        echo "Skipping Speechify Tom: no spfy build is published for ${TARGETARCH} yet. Piper and espeak-ng remain available."; \
        exit 0; \
    fi; \
    if [ "${SPFY_SLUG}" = "x86" ]; then \
        dpkg --add-architecture i386; \
        apt-get update; \
        apt-get install -y --no-install-recommends libc6:i386; \
        rm -rf /var/lib/apt/lists/*; \
    fi; \
    SHA_ARG="SPFY_ASSET_SHA256_$(echo "${TARGETARCH}" | tr 'a-z' 'A-Z')"; \
    if [ "${SPFY_VERSION}" = "latest" ]; then \
        RELEASE_URL="https://api.github.com/repos/${SPFY_REPO}/releases/latest"; \
    else \
        RELEASE_URL="https://api.github.com/repos/${SPFY_REPO}/releases/tags/${SPFY_VERSION}"; \
    fi; \
    if ! curl -fL --retry 5 --retry-delay 2 -H 'Accept: application/vnd.github+json' \
            -o /tmp/spfy-release.json "${RELEASE_URL}"; then \
        echo "Could not read ${RELEASE_URL}. Set --build-arg SPFY_VERSION=<tag> and --build-arg ${SHA_ARG}=<digest> to build without the GitHub API." >&2; \
        exit 1; \
    fi; \
    SPFY_RELEASE="$(jq -r '.tag_name // empty' /tmp/spfy-release.json)"; \
    if [ -z "${SPFY_RELEASE}" ]; then \
        echo "No tag_name in the release metadata at ${RELEASE_URL}." >&2; \
        exit 1; \
    fi; \
    ASSET_NAME="spfy-linux-${SPFY_SLUG}-${SPFY_RELEASE}.tar.gz"; \
    ASSET_URL="$(jq -r --arg n "${ASSET_NAME}" '.assets[] | select(.name == $n) | .browser_download_url' /tmp/spfy-release.json)"; \
    if [ -z "${ASSET_URL}" ]; then \
        echo "Release ${SPFY_RELEASE} publishes no asset named ${ASSET_NAME}. It has:" >&2; \
        jq -r '.assets[].name' /tmp/spfy-release.json >&2; \
        exit 1; \
    fi; \
    if [ -z "${SPFY_SHA256}" ]; then \
        SPFY_SHA256="$(jq -r --arg n "${ASSET_NAME}" '.assets[] | select(.name == $n) | .digest // empty' /tmp/spfy-release.json)"; \
    fi; \
    SPFY_SHA256="$(printf '%s' "${SPFY_SHA256}" | tr -d '[:space:]')"; \
    SPFY_SHA256="${SPFY_SHA256#sha256:}"; \
    SPFY_SHA256="${SPFY_SHA256#SHA256:}"; \
    SPFY_SHA256="$(printf '%s' "${SPFY_SHA256}" | tr 'A-F' 'a-f')"; \
    if ! printf '%s' "${SPFY_SHA256}" | grep -Eq '^[0-9a-f]{64}$'; then \
        echo "No usable sha256 for ${ASSET_NAME}: the release metadata carries no digest. Pass --build-arg ${SHA_ARG}=<digest> instead." >&2; \
        exit 1; \
    fi; \
    echo "Speechify: ${ASSET_NAME} from release ${SPFY_RELEASE} (sha256 ${SPFY_SHA256})"; \
    TEMP_DIR="/tmp/spfy"; \
    curl -fL --retry 5 --retry-delay 2 -o "/tmp/${ASSET_NAME}" "${ASSET_URL}"; \
    echo "${SPFY_SHA256}  /tmp/${ASSET_NAME}" | sha256sum -c -; \
    mkdir -p "${TEMP_DIR}" "/app/voices/tom"; \
    tar -xzf "/tmp/${ASSET_NAME}" -C "${TEMP_DIR}" --strip-components=1; \
    mv "${TEMP_DIR}/bin/spfy_synth" /usr/local/bin/spfy_synth; \
    chmod +x /usr/local/bin/spfy_synth; \
    mv "${TEMP_DIR}/en-US/tom" /app/voices; \
    chmod -R 755 /app/voices; \
    rm -rf "/tmp/${ASSET_NAME}" "${TEMP_DIR}" /tmp/spfy-release.json;

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
