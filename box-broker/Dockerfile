# box-broker — the single socket-holding sidecar. Tiny: the docker CLI (to run muster-box.sh's
# `docker run`), bash (muster-box.sh uses arrays), and python3 (the ~200-line HTTP service).
FROM docker:cli

# WHICH MUSTER THIS IS. Baked in so the pieces can check they agree at runtime: the hub, the broker
# and the boxes are three images from three build paths, and nothing else stops a stack from running
# a 0.2 broker against a 0.1 hub. The ADD-ON images inherit this ENV from their base, so a
# project's own toolchain layer carries the version of the muster it was built on — which is exactly
# the number that has to match. `dev` when built by hand; CI passes the release tag.
ARG MUSTER_VERSION=dev
ENV MUSTER_VERSION=${MUSTER_VERSION}

RUN apk add --no-cache python3 bash

# The one place that knows how to spawn a Claude box on Docker is muster-box.sh, shared with the
# laptop flow; the broker just invokes it (headless/detached) with a vetted environment.
COPY muster-box.sh /usr/local/bin/muster-box.sh
COPY box-broker/broker.py /usr/local/bin/broker.py
RUN chmod 0755 /usr/local/bin/muster-box.sh /usr/local/bin/broker.py

# Runs as root so it can reach the mounted docker socket — it is the trusted, minimal component;
# claude and the dev toolchain never run here.
ENTRYPOINT ["python3", "/usr/local/bin/broker.py"]
