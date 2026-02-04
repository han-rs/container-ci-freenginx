#!/bin/sh

set -e

# Check if podman is installed
if ! command -v podman >/dev/null 2>&1; then
    echo "Error: podman is not installed. Please install podman first."
    exit 1
fi

# Parse arguments
RESTART=${RESTART:-"false"}
SKIP_EDIT=${SKIP_EDIT:-"false"}
UPDATE_CONF=${UPDATE_CONF:-"false"}

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
        --update-conf)
            UPDATE_CONF="true"
            shift
            ;;
    esac
done

# Handle --update-conf flag
if [ "$UPDATE_CONF" = "true" ]; then
    echo "Updating configuration files in container..."
    
    # Check if conf directory exists
    if [ ! -d "./conf/conf.d" ]; then
        echo "Error: ./conf/conf.d directory not found"
        exit 1
    fi
    
    if [ ! -f "./conf/nginx.conf" ]; then
        echo "Error: ./conf/nginx.conf file not found"
        exit 1
    fi
    
    # Execute in podman unshare context
    podman unshare sh -c '
        set -e
        echo "Mounting freenginx container..."
        dir=$(podman mount freenginx)
        
        if [ -z "$dir" ]; then
            echo "Error: Failed to mount container"
            exit 1
        fi
        
        echo "Container mounted at: $dir"
        
        # Create target directory if it does not exist
        mkdir -p "$dir/opt/nginx/conf/conf.d"
        
        # Copy conf.d directory contents (preserve non-existing, overwrite existing)
        echo "Copying conf.d directory..."
        cp -rf ./conf/conf.d/* "$dir/opt/nginx/conf/conf.d/"
        
        # Copy nginx.conf file
        echo "Copying nginx.conf..."
        cp -f ./conf/nginx.conf "$dir/opt/nginx/conf/nginx.conf"
        
        echo "Unmounting container..."
        podman unmount freenginx
        
        echo "Configuration files updated successfully!"
    '

    if [ $? -eq 0 ]; then
        echo "Done! Reload the service to apply changes: systemctl --user reload freenginx"
        exit 0
    else
        echo "Error: Failed to update configuration files"
        exit 1
    fi
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
