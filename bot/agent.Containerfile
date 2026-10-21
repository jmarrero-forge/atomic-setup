# Image for bootc-bot job containers: one disposable container per request.
# Build: podman build -t localhost/bootc-bot-agent -f bot/agent.Containerfile bot/
FROM registry.fedoraproject.org/fedora:45

RUN dnf install -y \
        # basics for reading and searching code
        git gh jq ripgrep fd-find diffutils patch findutils procps-ng python3 hostname which \
        # to push branches to and run builds on devspace runners over the tailnet
        openssh-clients rsync tmux just \
        # so agents can build and test Rust projects like bootc
        cargo rust clippy rustfmt gcc make pkgconf-pkg-config \
        # bootc/ostree tooling to inspect behavior, man pages and images
        bootc ostree skopeo man-db \
        # runtime for the agent CLIs
        nodejs npm && \
    dnf clean all

# opencode is pinned to the version the coordinator's opencode backend was
# tested with: its Copilot provider pin, its policies and its builder
# agent's rules rest on how opencode merges its config sources. Before each
# bump, re-run the coordinator image's config check, which plants config of
# each kind, with and without the loop's pre-start clean, and plants more
# into a running server (opencode reloads config files as they change):
#   podman run --rm --entrypoint python3 localhost/bot-coordinator \
#       /usr/local/share/bot-coordinator/check-opencode-config.py
RUN npm install -g @anthropic-ai/claude-code @openai/codex @github/copilot @opencode/cli@2.1.1 && \
    npm cache clean --force
# opencode 2 no longer reads OPENCODE_AUTH_CONTENT: this runs it with that
# login (see the script).
COPY --chmod=755 opencode-copilot /usr/local/bin/opencode-copilot
# opencode's own update check reads only the global config, which a job or
# session can write; the npm install isn't the agent user's to replace anyway.
# Its database's name, which would otherwise depend on the release channel:
# opencode-copilot and the coordinator's archive scrub look for this one.
ENV OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DB=opencode.db

# The bot's commit identity, for any commit made in a job.
RUN git config --system user.name "Joseph Marrero" && \
    git config --system user.email "jmarrero+bot@gmail.com" && \
    # Let git use gh's token for https pushes (what `gh auth setup-git` does).
    # gh reads it from GH_TOKEN, which only the bot's own container is given
    # (a podman secret); botd's Q&A jobs get none, so this helper finds nothing.
    git config --system credential.https://github.com.helper "" && \
    git config --system --add credential.https://github.com.helper "!gh auth git-credential" && \
    git config --system credential.https://gist.github.com.helper "" && \
    git config --system --add credential.https://gist.github.com.helper "!gh auth git-credential"

# Never prompt in unattended runs; push over https so the helper above applies.
ENV GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 GH_NO_EXTENSION_UPDATE_NOTIFIER=1

# botd runs jobs as uid 2000, mapped to the host user with --userns=keep-id
RUN useradd -m -u 2000 -s /bin/bash agent
USER agent
WORKDIR /home/agent
# Bind mounts must not cause Podman to create these as root-owned directories.
RUN mkdir -m 700 /home/agent/.codex /home/agent/.claude
RUN gh config set git_protocol https
