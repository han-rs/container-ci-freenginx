#!/bin/bash

set -e

# Should sync with the one in install.sh and freenginx.container
CONF_FILE="${1:-$HOME/.local/share/freenginx/conf/conf.d/cloudflare-real-ip.conf}"

echo "# \* Extract client IPs from requests proxied by Cloudflare" > "$CONF_FILE";

echo "real_ip_header CF-Connecting-IP;" >> "$CONF_FILE";

for i in `curl https://www.cloudflare.com/ips-v4`; do
    echo "set_real_ip_from $i;" >> "$CONF_FILE";
done

for i in `curl https://www.cloudflare.com/ips-v6`; do
    echo "set_real_ip_from $i;" >> "$CONF_FILE";
done

echo "" >> "$CONF_FILE";
