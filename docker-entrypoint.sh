#!/bin/sh
set -e

# If the first argument looks like a flag, assume we are running bitcoind.
if [ "${1#-}" != "$1" ]; then
    set -- bitcoind "$@"
fi

# When running bitcoind/bitcoin-cli/bitcoin-tx, make sure the data dir exists,
# is owned by the unprivileged "bitcoin" user, and drop privileges to it.
case "$1" in
    bitcoind|bitcoin-cli|bitcoin-tx)
        : "${BITCOIN_DATA:=/data/.bitcoin}"
        mkdir -p "$BITCOIN_DATA"

        # Point bitcoind at the data dir unless the caller already did.
        if [ "$1" = "bitcoind" ] || [ "$1" = "bitcoin-cli" ]; then
            case " $* " in
                *" -datadir="*) ;;
                *) set -- "$@" "-datadir=$BITCOIN_DATA" ;;
            esac
        fi

        if [ "$(id -u)" = "0" ]; then
            chown -R bitcoin:bitcoin "$BITCOIN_DATA"
            exec su-exec bitcoin "$@"
        fi
        exec "$@"
        ;;
esac

exec "$@"
