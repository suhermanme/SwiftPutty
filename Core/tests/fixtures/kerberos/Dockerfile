# A throwaway Kerberos realm and a GSSAPI SSH server for spb_ssh_test
# (M13, D-044). Test-only: every password and key here is public.
#
#   realm      SWIFTPUTTY.TEST (MIT KDC, TCP)
#   user       tester@SWIFTPUTTY.TEST, Kerberos password "kerberos-pw";
#              Unix user tester, password "weasel" (the fallback)
#   service    host/localhost@SWIFTPUTTY.TEST in /etc/krb5.keytab
#   sshd       GSSAPI authentication and (Debian's patch) GSSAPI key
#              exchange; password authentication as the fallback
FROM debian:bookworm-slim

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        krb5-kdc krb5-admin-server krb5-user openssh-server \
 && rm -rf /var/lib/apt/lists/*

COPY krb5.conf /etc/krb5.conf
COPY kdc.conf /etc/krb5kdc/kdc.conf
COPY sshd_config /etc/ssh/sshd_config.d/swiftputty.conf
COPY start.sh /start.sh

RUN useradd -m -s /bin/sh tester \
 && echo 'tester:weasel' | chpasswd \
 && mkdir -p /run/sshd \
 && kdb5_util create -s -r SWIFTPUTTY.TEST -P master-pw \
 && kadmin.local -q 'addprinc -pw kerberos-pw tester' \
 && kadmin.local -q 'addprinc -randkey host/localhost' \
 && kadmin.local -q 'ktadd -k /etc/krb5.keytab host/localhost' \
 && chmod 755 /start.sh

EXPOSE 22 88
CMD ["/start.sh"]
