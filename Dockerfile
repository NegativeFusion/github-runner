# base
FROM ubuntu:26.04

# set the github runner version ("latest" resolves to the newest release at build time)
ARG RUNNER_VERSION="latest"

# uid/gid the runner runs as; set them to match the host (see .env) so the
# runner can write to bind-mounted host folders and use the host docker socket
ARG RUNNER_UID=1000
ARG DOCKER_GID=999

# update the base packages and add a non-sudo user (the image's default
# "ubuntu" user is removed so its uid/gid 1000 are free to reuse)
RUN apt-get update -y && apt-get upgrade -y \
    && (userdel -r ubuntu 2>/dev/null || true) \
    && groupadd -g ${DOCKER_GID} docker && useradd -u ${RUNNER_UID} -g docker -m docker

# tools jobs commonly expect, as on GitHub's hosted runners: git (without it
# actions/checkout downloads a tarball instead of a repo), git-lfs, ssh,
# archives, rsync, make, python3, and jq to parse JSON
# (apt-get update runs in the same layer so a cached, stale package index
# can't point at versions the mirror has since removed)
RUN apt-get update -y \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    curl wget ca-certificates jq \
    git git-lfs openssh-client gnupg \
    zip unzip xz-utils rsync make \
    python3 python3-venv \
    && rm -rf /var/lib/apt/lists/*

# copy docker cli and the compose plugin (docker-compose v1 is no longer packaged)
COPY --from=docker:dind /usr/local/bin/docker /usr/local/bin/
COPY --from=docker:dind /usr/local/libexec/docker/cli-plugins/docker-compose /usr/local/libexec/docker/cli-plugins/
# buildx makes docker build use BuildKit (--progress, cache mounts, ...)
# instead of the deprecated legacy builder
COPY --from=docker:dind /usr/local/libexec/docker/cli-plugins/docker-buildx /usr/local/libexec/docker/cli-plugins/

# keep the legacy "docker-compose" command working for older workflows
RUN ln -s /usr/local/libexec/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose

# fetch the latest release info; ADD re-downloads on every build, so the cache
# is invalidated (and the runner re-downloaded) whenever a new release ships
ADD https://api.github.com/repos/actions/runner/releases/latest /tmp/runner-release.json

# cd into the user directory, download and unzip the github actions runner
RUN if [ "${RUNNER_VERSION}" = "latest" ]; then \
        RUNNER_VERSION=$(jq -r .tag_name /tmp/runner-release.json | sed 's/^v//'); \
    fi \
    && test -n "${RUNNER_VERSION}" && [ "${RUNNER_VERSION}" != "null" ] \
    && echo "Installing GitHub Actions runner ${RUNNER_VERSION}" \
    && cd /home/docker && mkdir actions-runner && cd actions-runner \
    && curl -fsSL -o runner.tar.gz https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz \
    && tar xzf runner.tar.gz && rm runner.tar.gz /tmp/runner-release.json

# install some additional dependencies
RUN chown -R docker ~docker && /home/docker/actions-runner/bin/installdependencies.sh

# copy over the start.sh script
COPY start.sh start.sh

# make the script executable
RUN chmod +x start.sh

# since the config and run script for actions are not allowed to be run by root,
# set the user to "docker" so all subsequent commands are run as the docker user
USER docker

# set the entrypoint to the start.sh script
ENTRYPOINT ["./start.sh"]

