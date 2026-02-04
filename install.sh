#!/bin/sh

set -e

# Check if podman is installed
if ! command -v podman >/dev/null 2>&1; then
    echo "Error: podman is not installed. Please install podman first."
    exit 1
fi

# Check if required files exist
if [ ! -f "./Dockerfile.prod" ]; then
    echo "Error: Dockerfile.prod not found"
    exit 1
fi

if [ ! -f "./assets/template.container" ]; then
    echo "Error: assets/template.container not found"
    exit 1
fi

# Parse arguments
RESTART=${RESTART:-"false"}
SKIP_EDIT=${SKIP_EDIT:-"false"}

for arg in "$@"; do
    case $arg in
        --restart)
            RESTART="true"
            shift
            ;;
        --skip-edit)
            SKIP_EDIT="true"
            shift
            ;;
    esac
done

echo "Pulling base image..."
if ! podman pull ghcr.io/han-rs/container-ci-freenginx:base; then
    echo "Error: Failed to pull base image. Check your network connection."
    exit 1
fi

echo "Building production image..."
if ! podman build \
    -f ./Dockerfile.prod \
    --build-arg UID=$(id -u) \
    --build-arg GID=$(id -g) \
    --build-arg http_proxy="${http_proxy:-""}" \
    --build-arg https_proxy="${https_proxy:-""}" \
    --format docker \
    -t ghcr.io/han-rs/container-ci-freenginx:prod; then
    echo "Error: Failed to build production image."
    exit 1
fi

if [ "$RESTART" = "true" ]; then
    echo "Restarting freenginx service..."
    systemctl --user restart freenginx
else
    mkdir -p ~/.config/containers/systemd

    # Check if config already exists
    if [ -f ~/.config/containers/systemd/freenginx.container ]; then
        echo "Warning: Existing freenginx.container will be backed up to freenginx.container.bak"
        cp ~/.config/containers/systemd/freenginx.container ~/.config/containers/systemd/freenginx.container.bak
    fi

    cp -f ./assets/template.container ~/.config/containers/systemd/freenginx.container

    # Edit if necessary (skip if --skip-edit is passed)
    if [ "$SKIP_EDIT" != "true" ]; then
        echo "Opening editor for configuration. Press Ctrl+X to exit nano."
        ${EDITOR:-nano} ~/.config/containers/systemd/freenginx.container
    fi

    # Reload systemd and start the service
    echo "Enabling linger for user (requires sudo)..."
    sudo loginctl enable-linger $USER

    echo "Starting freenginx service..."
    systemctl --user daemon-reload
    systemctl --user start freenginx

    echo "Done! Check service status with: systemctl --user status freenginx"
fi
