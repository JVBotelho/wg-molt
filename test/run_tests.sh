#!/bin/sh

cd "$(dirname "$0")"

echo "=== Running tests in Alpine ==="
docker run --rm -v "$(pwd)/..:/app" -w /app/test alpine sh test_m1.sh

echo "=== Running tests in BusyBox ==="
docker run --rm -v "$(pwd)/..:/app" -w /app/test busybox sh test_m1.sh

echo "=== Running shellcheck ==="
# We can use a shellcheck docker image to run it easily
docker run --rm -v "$(pwd)/..:/app" -w /app koalaman/shellcheck:stable --shell=sh src/lib/log.sh src/lib/journal.sh test/test_m1.sh
