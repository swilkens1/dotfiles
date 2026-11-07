# Throwaway Ubuntu image for tests/run.sh. A fresh user with the distro's
# /etc/skel dotfiles, so bootstrap meets the same pre-existing files as on a
# new machine.
FROM ubuntu:26.04

# Optional corporate CA (tests/run.sh copies TEST_CA_BUNDLE here; otherwise
# the directory is empty). Installed before apt so HTTPS mirrors work too.
COPY ca/ /usr/local/share/ca-certificates/

# openssh-client matches a stock Ubuntu/WSL install (the container image omits it).
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates git openssh-client \
 && rm -rf /var/lib/apt/lists/*

# Stand-in for Homebrew: reports every formula as installed, so the test
# exercises deployment instead of a 10+ minute network install.
RUN mkdir -p /opt/stubs/bin \
 && printf '#!/bin/sh\nexit 0\n' > /opt/stubs/bin/brew \
 && chmod +x /opt/stubs/bin/brew

RUN useradd --create-home --shell /bin/bash tester
USER tester
WORKDIR /home/tester
