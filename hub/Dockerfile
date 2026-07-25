# claude-box-hub — the per-project "hosting dev environment" for the remote/server setup.
#
# It owns the git checkout and runs the dev services the agent boxes use: the backend
# (gradle bootRun), the Angular dev server (ng serve), and the pinchtab server + its
# self-managed headless Chrome. It does NOT run claude — the agent boxes (separate
# claude-box containers, spawned by the box-broker) do. This is where YOU review + commit
# the edits the agents make (it holds the git identity; the boxes do not).
#
# Same JDK17 + gradle base as docker-gradle, plus node (for ng serve), the Chrome runtime
# libs pinchtab's browser needs, and the pinchtab server binary. Runs as the base image's
# non-root 'gradle' user (uid 1000), so bind-mounted files line up with a numeric owner and
# no host account is needed.
FROM gradle:8-jdk17-jammy

USER root

# Runtime deps. The cypress/Chrome shared-lib list mirrors docker-gradle (pinchtab downloads
# and drives its own Chrome, so we only need the libs, not the browser package). tmux holds the
# on-demand service windows; git clones + commits; jq/python3/procps for the helper scripts.
RUN apt-get update && apt-get install -y --no-install-recommends \
		ca-certificates curl git tmux less jq python3 procps unzip \
		libgtk2.0-0 libgtk-3-0 libgbm-dev libnotify-dev libgconf-2-4 libnss3 \
		libxss1 libasound2 libxtst6 xauth xvfb \
	&& rm -rf /var/lib/apt/lists/*

# Node + npm via fnm, pinned to the host dev versions (override with --build-arg). System-wide,
# outside the home bind mount, symlinked onto PATH — same approach as the claude-box image.
ARG NODE_VERSION=v26.2.0
ARG NPM_VERSION=11.13.0
ENV FNM_DIR=/opt/fnm
RUN curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir /usr/local/bin --skip-shell \
	&& fnm install "${NODE_VERSION}" \
	&& fnm default "${NODE_VERSION}" \
	&& ln -s "${FNM_DIR}/node-versions/${NODE_VERSION}/installation/bin/"* /usr/local/bin/ \
	&& npm install -g "npm@${NPM_VERSION}" \
	&& node --version && npm --version

# pinchtab SERVER (the box ships only the CLI; the hub runs the server + Chrome). The npm package
# is a launcher that fetches a self-contained Go binary; install it in a throwaway HOME, copy the
# binary onto PATH, drop the wrapper. Pinned to the host version.
ARG PINCHTAB_VERSION=0.13.2
RUN HOME=/tmp/pt npm install -g "pinchtab@${PINCHTAB_VERSION}" \
	&& cp "$(find /tmp/pt/.pinchtab -name 'pinchtab-linux-amd64' -type f | head -1)" /usr/local/bin/pinchtab \
	&& chmod 0755 /usr/local/bin/pinchtab \
	&& npm rm -g pinchtab \
	&& rm -rf /tmp/pt \
	&& pinchtab --version

ENV NG_CLI_ANALYTICS=false

# Helper CLI (cbx: start/stop services, spawn/kill boxes via the broker) + entrypoint.
COPY cbx /usr/local/bin/cbx
COPY entrypoint.sh /usr/local/bin/hub-entrypoint.sh
RUN chmod 0755 /usr/local/bin/cbx /usr/local/bin/hub-entrypoint.sh

USER 1000
WORKDIR /home/gradle
ENTRYPOINT ["/usr/local/bin/hub-entrypoint.sh"]
