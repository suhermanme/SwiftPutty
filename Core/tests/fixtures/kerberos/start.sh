#!/bin/sh
# KDC in the background, sshd in the foreground (logs to stderr).
set -e
krb5kdc
exec /usr/sbin/sshd -D -e
