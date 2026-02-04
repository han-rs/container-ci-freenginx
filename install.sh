#!/bin/sh

set -e

podman build \
    -f ./Dockerfile.prod \
    --build-arg UID=$(id -u) \
    --build-arg GID=$(id -g) \
    --build-arg http_proxy="${http_proxy:-""}" \
    --build-arg https_proxy="${https_proxy:-""}" \
    --format docker \
    -t ghcr.io/han-rs/container-ci-freenginx:prod

# Install container service
mkdir -p ~/.config/containers/systemd
cp -f ./assets/template.container ~/.config/containers/systemd/freenginx.container

# Enable container service
systemctl --user daemon-reload
systemctl --user start freenginx
