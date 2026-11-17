#!/usr/bin/env bash
# Entrypoint of every member of a MongoDB replica set (#164), on the official mongo image (7).
#
# With authentication on, the members of a replica set authenticate to each other with a shared key file, which
# mongod accepts only when its owner is the mongodb user and its mode is 400. A bind-mounted file has the host's
# owner, so the key comes from MONGO_REPLICA_KEY instead and is written here, then the image's entrypoint starts
# mongod with --replSet and --keyFile. The image's first-run init (the root user of MONGO_INITDB_ROOT_*) drops
# --replSet while it runs, and only the first member gets the root user: the others must start empty, or
# rs.initiate refuses them ("has data already"). They receive the users from the first member by initial sync.
#
# Environment: MONGO_REPLICA_KEY (6 to 1024 base64 characters, the same on every member of the set), MONGO_REPLSET
# (default rs0), and on the first member only MONGO_INITDB_ROOT_USERNAME / MONGO_INITDB_ROOT_PASSWORD.
set -euo pipefail

: "${MONGO_REPLICA_KEY:?set MONGO_REPLICA_KEY: 6 to 1024 base64 characters, the same on every member}"
key=/data/rs/keyfile
install -d -o mongodb -g mongodb -m 700 /data/rs
printf '%s' "$MONGO_REPLICA_KEY" > "$key"
chown mongodb:mongodb "$key"
chmod 400 "$key"
exec docker-entrypoint.sh mongod --replSet "${MONGO_REPLSET:-rs0}" --keyFile "$key" --bind_ip_all
