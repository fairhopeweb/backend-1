#!/bin/bash

set -u
set -e

# Update memory configuration
/opt/postgresql-base/bin/generate_runtime_config.sh

# Run schema migrations if needed
if [ -e /var/lib/postgresql/first_run ]; then
    echo "Skipping schema migrations on first run..."
    rm /var/lib/postgresql/first_run
elif [ ! -z ${MC_POSTGRESQL_SKIP_MIGRATIONS+x} ]; then
    # Used for verifying whether ZFS backup snapshot works
    echo "Skipping schema migrations because 'MC_POSTGRESQL_SKIP_MIGRATIONS' is set."
else
    echo "Applying schema migrations..."
    /opt/postgresql-server/bin/apply_migrations.sh
    echo "Done applying schema migrations."
fi

# Start PostgreSQL
exec /opt/postgresql-base/bin/postgresql.sh
