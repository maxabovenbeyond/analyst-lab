#!/usr/bin/env bash
set -e
cd ~/projects/analyst-lab
for f in ddl seed seed-claims; do
    echo "=== $f.sql ==="
    docker cp "02-sql/$f.sql" "lab-postgres:/tmp/$f.sql"
    docker exec lab-postgres psql -U lab -d lab -v ON_ERROR_STOP=1 -q -f "/tmp/$f.sql"
done
echo "Готово: схема delivery пересоздана и наполнена"