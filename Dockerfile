# syntax=docker/dockerfile:1
#
# Bitcoin Core 0.12.1 — multi-stage build producing a small Alpine runtime image
# with bitcoind, bitcoin-cli and bitcoin-tx.
#
# Why we build against LibreSSL (not OpenSSL):
#   wallet/crypter.cpp uses the OpenSSL 1.0.x API (a stack-allocated
#   EVP_CIPHER_CTX with EVP_CIPHER_CTX_init/cleanup). OpenSSL 1.1+/3.x make that
#   type opaque, so the code will not compile against modern OpenSSL. LibreSSL
#   keeps the transparent struct + legacy API, so we link both build and runtime
#   stages against LibreSSL and the sonames match.
#
# Boost (needs the const-comparator patch) on musl libc (needs the <fcntl.h>
# include fix) is handled by patches/.
#
# BerkeleyDB 4.8 is not packaged by Alpine, so it is built from source as a
# static library (same options the project's depends/ system uses) and linked
# into the binaries — this keeps wallet files compatible with upstream builds
# and leaves no db runtime dependency in the final image.

ARG ALPINE_VERSION=3.11
ARG BITCOIN_PREFIX=/opt/bitcoin

############################
# Stage 1: build everything
############################
FROM alpine:${ALPINE_VERSION} AS builder

# Toolchain + headers needed to compile Bitcoin Core and BerkeleyDB.
RUN apk add --no-cache \
        autoconf \
        automake \
        libtool \
        pkgconf \
        build-base \
        patch \
        wget \
        ca-certificates \
        linux-headers \
        boost-dev \
        libevent-dev \
        libressl-dev

# Modern config.guess/config.sub — BDB 4.8's bundled ones (2009) predate
# aarch64 and reject this host with "cannot guess build type".
COPY depends/config.guess depends/config.sub /usr/share/autoconf-helpers/

# ---- BerkeleyDB 4.8.30.NC (static) ----
ARG BDB_VERSION=4.8.30
ARG BDB_SHA256=12edc0df75bf9abd7f82f821795bcee50f42cb2e5f76a6a281b85732798364ef
ARG BDB_PREFIX=/opt/db4
RUN set -eux; \
    cd /tmp; \
    wget -q "https://download.oracle.com/berkeley-db/db-${BDB_VERSION}.NC.tar.gz" \
        || wget -q "http://download.oracle.com/berkeley-db/db-${BDB_VERSION}.NC.tar.gz" ; \
    echo "${BDB_SHA256}  db-${BDB_VERSION}.NC.tar.gz" | sha256sum -c -; \
    tar -xzf "db-${BDB_VERSION}.NC.tar.gz"; \
    cd "db-${BDB_VERSION}.NC"; \
    # gcc >= 4.7 clashes with BDB's __atomic_compare_exchange (same fix depends/ uses)
    sed -i 's/__atomic_compare_exchange/__atomic_compare_exchange_db/' dbinc/atomic.h; \
    # musl's <stdatomic.h> defines atomic_init, which collides with BDB's macro;
    # rename the macro and every call site (all files that reference it).
    sed -i 's/\batomic_init\b/__db_atomic_init/g' \
        dbinc/atomic.h \
        mp/mp_fget.c mp/mp_mvcc.c mp/mp_region.c \
        mutex/mut_method.c mutex/mut_tas.c; \
    cp /usr/share/autoconf-helpers/config.guess \
       /usr/share/autoconf-helpers/config.sub dist/; \
    cd build_unix; \
    ../dist/configure \
        --enable-cxx \
        --disable-shared \
        --disable-replication \
        --with-pic \
        --prefix="${BDB_PREFIX}"; \
    make -j"$(nproc)" libdb_cxx-4.8.a libdb-4.8.a; \
    make install_lib install_include; \
    rm -rf /tmp/db-${BDB_VERSION}.NC*

# ---- Bitcoin Core ----
WORKDIR /bitcoin
COPY . .

ARG BDB_PREFIX=/opt/db4
ARG BITCOIN_PREFIX
RUN set -eux; \
    # Apply the build-compatibility patches (paths are repo-root relative -> -p0).
    patch -p0 < patches/boost.patch; \
    patch -p0 < patches/warnings.patch; \
    # Security backports.
    patch -p0 < patches/cve-2017-18350-socks5.patch; \
    patch -p0 < patches/cve-2024-52916-header-spam.patch; \
    patch -p0 < patches/cve-2020-14198-banlist-bound.patch; \
    patch -p0 < patches/cve-2021-31876-rbf-inherited-signaling.patch; \
    patch -p0 < patches/cve-2024-52915-inv-getheaders-flood.patch; \
    patch -p0 < patches/tcp-urgent-data-oom.patch; \
    patch -p0 < patches/cve-2024-52912-timestamp-overflow.patch; \
    patch -p0 < patches/cve-2024-52919-addr-rate-limit.patch; \
    # Customization (non-security): advertise /Satoshi:0.12.1/jaonoctus/.
    patch -p0 < patches/subversion-jaonoctus.patch; \
    ./autogen.sh; \
    ./configure \
        LDFLAGS="-L${BDB_PREFIX}/lib/" \
        CPPFLAGS="-I${BDB_PREFIX}/include/" \
        --prefix="${BITCOIN_PREFIX}" \
        --disable-man \
        --without-gui \
        --with-utils \
        --with-daemon \
        --disable-tests \
        --disable-bench; \
    make -j"$(nproc)"; \
    make install; \
    strip "${BITCOIN_PREFIX}/bin/bitcoind" \
          "${BITCOIN_PREFIX}/bin/bitcoin-cli" \
          "${BITCOIN_PREFIX}/bin/bitcoin-tx"

############################
# Stage 2: runtime image
############################
FROM alpine:${ALPINE_VERSION}
ARG BITCOIN_PREFIX

# Only the shared libraries the binaries actually link against (verified with
# ldd). BerkeleyDB is absent on purpose — it was statically linked in stage 1.
# libsodium/libzmq would only be needed for a --with-zmq build, and protobuf
# only for the GUI, so none of those are installed. libstdc++ pulls in libgcc.
#
# Also create the unprivileged "bitcoin" user/group the container runs as.
# Its home is /data so HOME-based datadir discovery resolves to the mount point
# /data/.bitcoin. BusyBox adduser flags: -S system user, -D no password,
# -H skip home skeleton (we mkdir + chown /data ourselves so the data volume is
# owned by bitcoin), -g "" empty GECOS.
RUN apk add --no-cache \
        boost-chrono \
        boost-filesystem \
        boost-program_options \
        boost-system \
        boost-thread \
        libevent \
        libressl \
        libstdc++ \
        su-exec \
    && addgroup -S bitcoin \
    && adduser -S -D -H -h /data -G bitcoin -g "" bitcoin \
    && mkdir -p /data/.bitcoin \
    && chown -R bitcoin:bitcoin /data

COPY --from=builder ${BITCOIN_PREFIX}/bin/bitcoind   /usr/local/bin/bitcoind
COPY --from=builder ${BITCOIN_PREFIX}/bin/bitcoin-cli /usr/local/bin/bitcoin-cli
COPY --from=builder ${BITCOIN_PREFIX}/bin/bitcoin-tx  /usr/local/bin/bitcoin-tx
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# HOME makes bitcoind/bitcoin-cli default to $HOME/.bitcoin, so `docker exec
# bitcoin-cli ...` finds the RPC cookie without needing -datadir.
ENV HOME=/data \
    BITCOIN_DATA=/data/.bitcoin
WORKDIR /data/.bitcoin
VOLUME ["/data/.bitcoin"]

# mainnet (p2p/rpc), testnet (p2p/rpc), regtest (p2p/rpc)
EXPOSE 8333 8332 18333 18332 18444 18443

# Run as the unprivileged user by default. `docker exec` inherits this USER
# (and HOME above), so bitcoin-cli works without flags. Override with
# `docker run --user 0` to let the entrypoint chown a root-owned bind mount.
USER bitcoin

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["bitcoind"]
