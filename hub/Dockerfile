# claude-box-hub (infostars) — the per-project hub image for the remote/server setup.
#
# It owns the git checkout and runs the dev services the agent boxes use: the backend
# (gradle bootRun), the Angular dev server (ng serve), and the pinchtab server + its
# self-managed headless Chrome. It does NOT run claude — the agent boxes (separate
# claude-box containers, spawned by the box-broker) do. This is where YOU review + commit
# the edits the agents make (it holds the git identity; the boxes do not).
#
# Everything project-agnostic (git/ssh, tmux, node, pinchtab, cbx, entrypoint, the JDK17 + gradle 8
# jammy base) lives in claude-box-hub-base (Dockerfile.base). This layer adds ONLY the extra
# infostars build deps on top: ant. Build the base first, then this — see README-remote.md.
ARG HUB_BASE_IMAGE=dockerregistry.acoveo.com/acoveo/claude-box-hub-base:stable
FROM ${HUB_BASE_IMAGE}

USER root

# Ant — needed by the infostars build (gradle + the JDK come from the base image).
RUN apt-get update && apt-get install -y --no-install-recommends ant \
	&& rm -rf /var/lib/apt/lists/*

# Back to the non-root hub user; WORKDIR + ENTRYPOINT are inherited from the base.
USER 1000
