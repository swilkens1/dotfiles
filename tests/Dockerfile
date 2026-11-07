# Throwaway Ubuntu image for tests/run.sh. A fresh user with the distro's
# /etc/skel dotfiles, so bootstrap meets the same pre-existing files as on a
# new machine.
FROM ubuntu:26.04

# Optional corporate CA (tests/run.sh copies TEST_CA_BUNDLE here; otherwise
# the directory is empty). Installed before apt so HTTPS mirrors work too.
COPY ca/ /usr/local/share/ca-certificates/

# openssh-client and bash-completion match a stock Ubuntu/WSL install (the
# container image omits them).
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates git openssh-client openssl bash-completion \
 && rm -rf /var/lib/apt/lists/*

# Recording stand-ins for sudo and curl: the tests check what bootstrap
# would install (apt, dpkg, downloads) without root or network access.
RUN mkdir -p /opt/stubs/bin \
 && for t in sudo curl; do \
      printf '#!/bin/sh\necho "$*" >> /tmp/%s.calls\n' "$t" > "/opt/stubs/bin/$t"; \
    done \
 && chmod +x /opt/stubs/bin/*

RUN useradd --create-home --shell /bin/bash tester
USER tester
WORKDIR /home/tester
