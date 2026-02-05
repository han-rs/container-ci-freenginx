#!/bin/sh

set -e

NC='\033[0m'

log_error() {
	RED='\033[0;31m'
	echo "${RED}$1${NC}"
}

log_success() {
	GREEN='\033[0;32m'
	echo "${GREEN}$1${NC}"
}

log_warning() {
	YELLOW='\033[1;33m'
	echo "${YELLOW}$1${NC}"
}

log_info() {
	BLUE='\033[0;34m'
	echo "${BLUE}$1${NC}"
}

# Check if podman is installed
if ! command -v podman >/dev/null 2>&1; then
	log_error "Error: podman is not installed. Please install podman first."
	exit 1
fi

# Non-interactive mode.
UPDATE_CONF=${UPDATE_CONF:-"false"}
UPGRADE=${UPGRADE:-"false"}
FULL_UPGRADE=${FULL_UPGRADE:-"false"}
NONINTERACTIVE=${NONINTERACTIVE:-"false"}

# Function to safely copy config file with backup
copy() {
	local src="$1"
	local dest="$2"

	# Check if source file or directory exists
	if [ ! -e "$src" ]; then
		log_error "Error: ${src} does not exist."
		exit 1
	fi

	# Check if config already exists
	if [ -e "$dest" ]; then
		log_warning "Warning: Existing ${dest} will be backed up"
		rm -rf "${dest}.bak"
		mv "$dest" "${dest}.bak"
	fi

	cp -rf "$src" "$dest"
}

copy_unshare() {
	local src="$1"
	local dest="$2"

	# Check if source file or directory exists
	if [ ! -e "$src" ]; then
		log_error "Error: ${src} does not exist."
		exit 1
	fi

	# Convert to absolute path
	src="$(realpath "$src")"

	podman unshare sh -c "
		set -e
		dir=\$(podman mount freenginx)

		if [ -z \"\$dir\" ]; then
			echo 'Error: Failed to mount container'
			exit 1
		fi

		# Create target directory if it does not exist
		mkdir -p \"\$(dirname \"\$dir${dest}\")\"

		# Backup existing file or directory if it exists
		if [ -e \"\$dir${dest}\" ]; then
			rm -rf \"\$dir${dest}.bak\"
			mv \"\$dir${dest}\" \"\$dir${dest}.bak\"
		fi

		# Copy file or directory to container
		cp -rf \"${src}\" \"\$dir${dest}\"

		podman unmount freenginx
	"

	if [ $? -eq 0 ]; then
		log_success "Successfully copied to container: ${dest}"
	else
		log_error "Error: Failed to copy file to container"
		exit 1
	fi
}

for arg in "$@"; do
	case $arg in
	--update-conf)
		UPDATE_CONF="true"
		shift
		;;
	--upgrade)
		UPGRADE="true"
		shift
		;;
	--full-upgrade)
		UPGRADE="true"
		FULL_UPGRADE="true"
		shift
		;;
	--noninteractive)
		NONINTERACTIVE="true"
		shift
		;;
	esac
done

if [ "$UPDATE_CONF" = "true" ]; then
	log_info "Updating configuration files..."

	copy_unshare ./conf/conf.d /opt/nginx/conf/conf.d
	copy_unshare ./conf/nginx.conf /opt/nginx/conf/nginx.conf

	systemctl --user reload freenginx

	log_success "Configuration files updated successfully."
	exit 0
fi

log_info "Pulling image..."

if ! podman pull ghcr.io/han-rs/container-ci-freenginx:latest; then
	log_error "Error: Failed to pull image."
	exit 1
fi

if [ "$UPGRADE" = "true" ]; then
	if [ "$FULL_UPGRADE" = "true" ]; then
		log_info "Updating freenginx service..."
		copy ./assets/freenginx.container ~/.config/containers/systemd/freenginx.container
		copy_unshare ./conf/conf.d /opt/nginx/conf/conf.d
		copy_unshare ./conf/nginx.conf /opt/nginx/conf/nginx.conf
		systemctl --user daemon-reload
	fi

	log_info "Restarting freenginx service..."
	systemctl --user restart freenginx
else
	mkdir -p ~/.config/containers/systemd
	copy ./assets/freenginx.container ~/.config/containers/systemd/freenginx.container

	# Edit if necessary (skip if --noninteractive is passed)
	if [ "$NONINTERACTIVE" != "true" ]; then
		log_info "Opening editor for configuration. Press Ctrl+X to exit nano."
		${EDITOR:-nano} ~/.config/containers/systemd/freenginx.container
	fi

	# Check if linger is already enabled
	if ! loginctl show-user $USER --property=Linger | grep -q "Linger=yes"; then
		if [ "$NONINTERACTIVE" = "true" ]; then
			log_warning "Warning: Linger not enabled for user. Please run manually: sudo loginctl enable-linger $USER"
		else
			log_info "Enabling linger for user (requires sudo)..."
			sudo loginctl enable-linger $USER
		fi
	fi

	log_info "Starting freenginx service..."

	systemctl --user daemon-reload
	systemctl --user start freenginx

	# Generate dhparam.pem
	log_info "Generating dhparam.pem (this may take a while)..."
	openssl dhparam -out /tmp/dhparam.pem 2048
	copy_unshare /tmp/dhparam.pem /opt/nginx/conf/dhparam.pem
	rm -f /tmp/dhparam.pem

	# Copy configuration files to container
	log_info "Copying configuration files to container..."
	copy_unshare ./conf/conf.d /opt/nginx/conf/conf.d
	copy_unshare ./conf/nginx.conf /opt/nginx/conf/nginx.conf

	log_success "Done! Check service status with: systemctl --user status freenginx"
fi
