#!/bin/sh
# The Kerberos fixture for spb_ssh_test (D-044).
#
#   fixture.sh start   build the image if needed, start a container, wait
#                      until its KDC and sshd answer; prints
#                      "<container id> <ssh port> <kdc port>" (loopback)
#   fixture.sh stop <container id>
#
# Exits 2 from start if Docker is not available, so the test can skip.
set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE=swiftputty-kerberos-test

case "${1:-}" in
  start)
    docker info >/dev/null 2>&1 || exit 2
    docker build -q -t "$IMAGE" "$DIR" >/dev/null
    cid="$(docker run -d --rm -p 127.0.0.1::22 -p 127.0.0.1::88 "$IMAGE")"
    ssh_port="$(docker port "$cid" 22/tcp | head -n 1 | sed 's/.*://')"
    kdc_port="$(docker port "$cid" 88/tcp | head -n 1 | sed 's/.*://')"
    # Ready when sshd sends its banner and the KDC accepts connections.
    i=0
    until docker exec "$cid" bash -c \
            'exec 3<>/dev/tcp/127.0.0.1/22 2>/dev/null' 2>/dev/null \
          || [ $i -ge 100 ]; do
        sleep 0.1; i=$((i + 1))
    done
    i=0
    until docker exec "$cid" pgrep -x krb5kdc >/dev/null 2>&1 || [ $i -ge 100 ]; do
        sleep 0.1; i=$((i + 1))
    done
    echo "$cid $ssh_port $kdc_port"
    ;;
  stop)
    docker rm -f "$2" >/dev/null 2>&1 || true
    ;;
  *)
    echo "usage: $0 start | stop <container id>" >&2
    exit 1
    ;;
esac
