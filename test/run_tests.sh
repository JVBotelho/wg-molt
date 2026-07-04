#!/bin/sh

cd "$(dirname "$0")"

echo "=== Running tests in Alpine ==="
docker run --rm -v "$(pwd)/..:/app" -w /app/test alpine sh -c "sh test_m1.sh && sh test_m2.sh"

echo "=== Running tests in BusyBox ==="
docker run --rm -v "$(pwd)/..:/app" -w /app/test busybox sh -c "sh test_m1.sh && sh test_m2.sh"

echo "=== Running shellcheck ==="
# We can use a shellcheck docker image to run it easily
docker run --rm -v "$(pwd)/..:/app" -w /app koalaman/shellcheck:stable --shell=sh src/lib/log.sh src/lib/journal.sh src/lib/api.sh test/test_m1.sh test/test_m2.sh test/mock_api.sh
