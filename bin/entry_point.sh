#!/bin/bash
set -euo pipefail

echo "Entry point script running"

CONFIG_FILE=_config.yml
ENTRYPOINT_PID_FILE=/tmp/westtide-entry_point.pid
JEKYLL_PORT=8080
JEKYLL_LIVERELOAD_PORT="${JEKYLL_LIVERELOAD_PORT:-35739}"
jekyll_pid=""

# Avoid starting duplicate watchdog processes when postAttachCommand runs multiple times.
if [ -f "$ENTRYPOINT_PID_FILE" ]; then
    existing_pid="$(cat "$ENTRYPOINT_PID_FILE" 2>/dev/null || true)"
    if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
        echo "Entry point already running (pid: $existing_pid). Skipping duplicate startup."
        exit 0
    fi
fi
echo "$$" > "$ENTRYPOINT_PID_FILE"

cleanup() {
    rm -f "$ENTRYPOINT_PID_FILE"
    if [ -n "${jekyll_pid:-}" ] && kill -0 "$jekyll_pid" 2>/dev/null; then
        kill "$jekyll_pid" 2>/dev/null || true
        wait "$jekyll_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# Function to manage Gemfile.lock
manage_gemfile_lock() {
    git config --global --add safe.directory '*'
    if command -v git &> /dev/null && [ -f Gemfile.lock ]; then
        if git ls-files --error-unmatch Gemfile.lock &> /dev/null; then
            echo "Gemfile.lock is tracked by git, keeping it intact"
            git restore Gemfile.lock 2>/dev/null || true
        else
            echo "Gemfile.lock is not tracked by git, removing it"
            rm Gemfile.lock
        fi
    fi
}

stop_existing_jekyll() {
    # If a previous jekyll server is still alive, stop it to avoid port conflicts.
    if pgrep -f "jekyll serve.*--port=${JEKYLL_PORT}" >/dev/null 2>&1; then
        echo "Found existing Jekyll process on port ${JEKYLL_PORT}, stopping it"
        pkill -f "jekyll serve.*--port=${JEKYLL_PORT}" || true
        sleep 1
    fi
}

start_jekyll() {
    manage_gemfile_lock
    stop_existing_jekyll
    bundle exec jekyll serve --watch --port="${JEKYLL_PORT}" --host=0.0.0.0 --livereload --livereload-port="${JEKYLL_LIVERELOAD_PORT}" --verbose --trace --force_polling &
    jekyll_pid=$!
}

start_jekyll

while true; do
    inotifywait -q -e modify,move,create,delete $CONFIG_FILE
    if [ $? -eq 0 ]; then
        echo "Change detected to $CONFIG_FILE, restarting Jekyll"
        if [ -n "${jekyll_pid:-}" ] && kill -0 "$jekyll_pid" 2>/dev/null; then
            kill "$jekyll_pid" 2>/dev/null || true
            wait "$jekyll_pid" 2>/dev/null || true
        fi
        start_jekyll
    fi
done
