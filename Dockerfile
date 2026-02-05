# Base Image Builder

# Base image
ARG ALPINE_BASE_VERSION=3.23.3
ARG ALPINE_BASE_HASH=25109184c71bdad752c8312a8623239686a9a2071e8825f20acb8f2198c3f659

# Image METADATA
ARG IMAGE_BUILD_DATE=1970-01-01T00:00:00+00:00
ARG IMAGE_VCS_REF=00000000

# The target FreeNGINX version to build
ARG FREENGINX_VERSION=1.29.4

# Dependencies versions
ARG OPENSSL_VERSION=3.6.1
ARG PCRE_VERSION=10.47
ARG ZLIB_COMMIT=12731092979c6d07f42da27da673a9f6c7b13586
ARG BROTLI_COMMIT=a71f9312c2deb28875acc7bacfdd5695a111aa53
ARG NGX_FANCYINDEX_COMMIT=cbc0d3fca4f06414612de441399393d4b3bbb315

# Non-root user and group IDs
ARG UID=65532
ARG GID=65532

# Proxy settings (if any)
ARG http_proxy=""
ARG https_proxy=""

# === Download Stage ===

FROM alpine:${ALPINE_BASE_VERSION}@sha256:${ALPINE_BASE_HASH} AS downloader

ARG http_proxy
ARG https_proxy

RUN set -e && \
    apk -U upgrade && apk add --no-cache \
    ca-certificates=20251003-r0 \
    git=2.52.0-r0

# Dont warn about detached head state
RUN set -e && \
    git config --global advice.detachedHead false

# === Source code: openssl/openssl ===

WORKDIR /tmp

ARG OPENSSL_VERSION

RUN set -e && \
    git clone --depth 1 --recursive -j8 --single-branch -b "openssl-${OPENSSL_VERSION}" https://github.com/openssl/openssl

# === Source code: PCRE2Project/pcre2 ===

WORKDIR /tmp

ARG PCRE_VERSION

RUN set -e && \
    git clone --depth 1 --recursive -j8 --single-branch -b "pcre2-${PCRE_VERSION}" https://github.com/PCRE2Project/pcre2

# === Source code: zlib-ng/zlib-ng ===

WORKDIR /tmp

RUN set -e \
    && \
    git clone --depth 1 --recursive -j8 --single-branch -b stable https://github.com/zlib-ng/zlib-ng

WORKDIR /tmp/zlib-ng

ARG ZLIB_COMMIT

RUN set -e \
    && \
    git checkout "${ZLIB_COMMIT}"

# === Source code: google/ngx_brotli ===

WORKDIR /tmp

RUN set -e \
    && \
    git clone --depth 1 --recurse-submodules -j8 https://github.com/google/ngx_brotli

WORKDIR /tmp/ngx_brotli

ARG BROTLI_COMMIT

RUN set -e \
    && \
    git checkout "${BROTLI_COMMIT}"

# === Source code: aperezdc/ngx-fancyindex ===

WORKDIR /tmp

RUN set -e \
    && \
    git clone --depth 1 --recurse-submodules -j8 https://github.com/aperezdc/ngx-fancyindex

WORKDIR /tmp/ngx-fancyindex

ARG NGX_FANCYINDEX_COMMIT

RUN set -e \
    && \
    git checkout "${NGX_FANCYINDEX_COMMIT}"

# === Source code: freenginx ===

WORKDIR /tmp

ARG FREENGINX_VERSION

RUN set -e \
    && \
    git clone --depth 1 --recursive -j8 --single-branch -b "release-${FREENGINX_VERSION}" https://github.com/freenginx/nginx

WORKDIR /tmp/nginx

RUN set -e \
    && \
    rm -rf docs/html/* \
    && \
    # Cleanup server header
    sed -ie 's@r->headers_out.server == NULL@0@g' \
    src/http/ngx_http_header_filter_module.c \
    src/http/v2/ngx_http_v2_filter_module.c \
    src/http/v3/ngx_http_v3_filter_module.c \
    && \
    sed -ie 's@<hr><center>freenginx</center>@@g' src/http/ngx_http_special_response.c

# === Builder Stage ===

FROM alpine:${ALPINE_BASE_VERSION}@sha256:${ALPINE_BASE_HASH} AS builder

ARG http_proxy
ARG https_proxy

WORKDIR /tmp

COPY --from=downloader /tmp/openssl /tmp/openssl
COPY --from=downloader /tmp/pcre2 /tmp/pcre2
COPY --from=downloader /tmp/zlib-ng /tmp/zlib-ng
COPY --from=downloader /tmp/ngx_brotli /tmp/ngx_brotli
COPY --from=downloader /tmp/ngx-fancyindex /tmp/ngx-fancyindex
COPY --from=downloader /tmp/nginx /tmp/nginx

RUN set -e && \
    apk -U upgrade && apk add --no-cache \
    build-base=0.5-r3 \
    cmake=4.1.3-r0 \
    perl=5.42.0-r0 \
    mimalloc2-dev=2.2.3-r2 \
    linux-headers=6.16.12-r0 \
    upx=5.0.2-r0

# === Build: zlib-ng ===

WORKDIR /tmp/zlib-ng

RUN set -e && \
    sed -i "s/compat=0/compat=1/" ./configure && \
    ./configure --zlib-compat && \
    make -j "$(nproc)" && \
    make install

# === Build: brotli ===

WORKDIR /tmp/ngx_brotli

RUN set -e && \
    mkdir -p ./deps/brotli/out && \
    cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_C_FLAGS="-m64 -march=x86-64 -mtune=generic -O3 -flto -funroll-loops -ffunction-sections -fdata-sections" \
    -DCMAKE_CXX_FLAGS="-m64 -march=x86-64 -mtune=generic -O3 -flto -funroll-loops -ffunction-sections -fdata-sections" \
    -DCMAKE_INSTALL_PREFIX=./installed \
    -B ./deps/brotli/out \
    -S ./deps/brotli && \
    cmake --build ./deps/brotli/out --config Release --target brotlienc

# === Build: freenginx ===

WORKDIR /tmp/nginx

RUN set -e && \
    ./auto/configure \
    --with-debug \
    --prefix="/opt/nginx" \
    --http-client-body-temp-path="/opt/nginx/temp/http-client-body" \
    --http-proxy-temp-path="/opt/nginx/temp/http-proxy" \
    --http-fastcgi-temp-path="/opt/nginx/temp/http-fastcgi" \
    --http-uwsgi-temp-path="/opt/nginx/temp/http-uwsgi" \
    --http-scgi-temp-path="/opt/nginx/temp/http-scgi" \
    --with-openssl="/tmp/openssl" \
    --with-openssl-opt=" \
    enable-ec_nistp_64_gcc_128 \
    no-tls1 \
    no-tls1_1 \
    no-shared \
    no-weak-ssl-ciphers \
    no-tls-deprecated-ec \
    enable-quic \
    enable-ktls \
    zlib" \
    --with-pcre="/tmp/pcre2" \
    --with-zlib="/tmp/zlib-ng" \
    --with-cc-opt=" \
    -static \
    -static-libgcc \
    -O3 \
    -march=x86-64 \
    -flto \
    -fhardened \
    -Wformat \
    -Wformat-security \
    -Werror=format-security \
    -fcode-hoisting \
    -Wno-deprecated-declarations \
    -DTCP_FASTOPEN=23" \
    --with-ld-opt=" \
    -L/usr/local/lib \
    -lz \
    -lmimalloc \
    -static \
    -Wl,--gc-sections" \
    --with-compat \
    --with-pcre-jit \
    --with-threads \
    --with-http_realip_module \
    --with-http_stub_status_module \
    --with-http_ssl_module \
    --with-http_v2_module \
    --with-http_v3_module \
    --with-http_gzip_static_module \
    --with-stream \
    --with-stream_realip_module \
    --with-stream_ssl_module \
    --with-stream_ssl_preread_module \
    --without-stream_split_clients_module \
    --without-stream_set_module \
    --without-http_geo_module \
    --without-http_scgi_module \
    --without-http_uwsgi_module \
    --without-http_split_clients_module \
    --without-http_memcached_module \
    --without-http_ssi_module \
    --without-http_empty_gif_module \
    --without-http_browser_module \
    --without-http_userid_module \
    --without-http_mirror_module \
    --without-http_referer_module \
    --without-mail_pop3_module \
    --without-mail_imap_module \
    --without-mail_smtp_module \
    --add-module="/tmp/ngx_brotli" \
    --add-module="/tmp/ngx-fancyindex"

RUN set -e && \
    make -j "$(nproc)" && \
    make install && \
    make clean

RUN set -e && \
    strip --strip-all /opt/nginx/sbin/nginx && \
    ldd /opt/nginx/sbin/nginx || true && \
    upx --best --lzma /opt/nginx/sbin/nginx

RUN set -e && \
    mkdir -p /opt/nginx/temp

# === Package Stage ===

FROM scratch

ARG IMAGE_BUILD_DATE
ARG IMAGE_VCS_REF

ARG FREENGINX_VERSION

ARG UID
ARG GID

# OCI labels for image metadata
LABEL description="FreeNGINX Distroless Image" \
    org.opencontainers.image.created=${IMAGE_BUILD_DATE} \
    org.opencontainers.image.authors="Hantong Chen <public-service@7rs.net>" \
    org.opencontainers.image.url="https://github.com/han-rs/container-ci-freenginx" \
    org.opencontainers.image.documentation="https://github.com/han-rs/container-ci-freenginx/blob/main/README.md" \
    org.opencontainers.image.source="https://github.com/han-rs/container-ci-freenginx" \
    org.opencontainers.image.version=${FREENGINX_VERSION}+image.${IMAGE_VCS_REF} \
    org.opencontainers.image.vendor="Hantong Chen" \
    org.opencontainers.image.licenses="BSD-2-Clause" \
    org.opencontainers.image.title="FreeNGINX Distroless Image" \
    org.opencontainers.image.description="FreeNGINX Distroless Image"

COPY --from=downloader /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=builder --chown="${UID}:${GID}" --chmod=775 /opt/nginx /opt/nginx
COPY --chown="${UID}:${GID}" --chmod=775 ./conf /opt/nginx/conf

# Health check for container orchestration
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=2 \
    CMD ["/opt/nginx/sbin/nginx", "-qt"]

# Use SIGQUIT for graceful shutdown with connection draining
STOPSIGNAL SIGQUIT

# Run as non-root user.
USER "${UID}:${GID}"

# Start in foreground mode
ENTRYPOINT ["/opt/nginx/sbin/nginx", "-g", "daemon off;"]
