#!/bin/sh
#
# config.sh
# ---------
# Central configuration for all borg-server scripts.
# Source this file at the beginning of each script:
#
#   . "$(dirname "$0")/../config.sh"
#

# Paths
CONF="config/clients.conf"
KEYDIR="config/keys"

# Container
CONTAINER="borg-server"
SERVICE="container-borg-server.service"
