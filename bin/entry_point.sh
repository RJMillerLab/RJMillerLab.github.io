#!/bin/bash

CONFIG_FILE=_config.yml
JEKYLL_PID=""

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

# Kill anything left over from a previous run. The devcontainer's
# postAttachCommand re-invokes this script on every reattach, and the
# upstream script wasn't idempotent: a stale Jekyll from a prior attach
# would still own ports 8080/35729 and the new instance would crash with
# "port is in use" on EventMachine.start_tcp_server.
kill_previous_instances() {
    local self_pid=$$
    local parent_pid=$PPID
    # Take down older bash invocations of this script. We deliberately
    # restrict the match to `bash ... bin/entry_point.sh` so we don't
    # accidentally kill the `/bin/sh -c "./bin/entry_point.sh"` wrapper
    # that postAttachCommand uses to spawn us — killing that wrapper
    # propagates SIGTERM to our own bash and drops us with exit 143.
    # Also defensively exclude our own pid and parent pid.
    local shells
    shells=$(pgrep -f 'bash[^ ]* .*bin/entry_point\.sh' \
        | grep -vw "$self_pid" \
        | grep -vw "$parent_pid" \
        || true)
    if [ -n "$shells" ]; then
        echo "Stopping previous entry_point.sh instances: $(echo $shells)"
        kill $shells 2>/dev/null || true
        sleep 1
        kill -KILL $shells 2>/dev/null || true
    fi
    # Belt-and-suspenders sweep for any orphan jekyll/inotifywait processes
    # whose parent script crashed before its trap could fire.
    local orphans
    orphans=$(pgrep -f 'jekyll serve|inotifywait .* _config\.yml' \
        | grep -vw "$self_pid" \
        | grep -vw "$parent_pid" \
        || true)
    if [ -n "$orphans" ]; then
        kill $orphans 2>/dev/null || true
        sleep 1
        kill -KILL $orphans 2>/dev/null || true
    fi
}

start_jekyll() {
    manage_gemfile_lock
    # The Docker Compose setup volume-mounts the project at /srv/jekyll and
    # uses a prebuilt image, so we (re)install gems into vendor/bundle to make
    # sure they match the mounted Gemfile.lock. The VS Code devcontainer (and
    # any other generic launcher) mounts the project elsewhere and runs
    # `bundle install` as part of postCreateCommand, so in that case we just
    # serve from the current working directory.
    if [ -d /srv/jekyll ] && [ -f /srv/jekyll/Gemfile ]; then
        (cd /srv/jekyll && bundle config set --local path 'vendor/bundle' && bundle install --quiet)
        (cd /srv/jekyll && bundle exec jekyll serve --watch --port=8080 --host=0.0.0.0 --livereload --verbose --trace --force_polling) &
    else
        bundle exec jekyll serve --watch --port=8080 --host=0.0.0.0 --livereload --verbose --trace --force_polling &
    fi
    JEKYLL_PID=$!
}

# When this script exits (terminal closed, devcontainer detach, Ctrl-C, etc.)
# take the Jekyll process down with us so it can't linger and conflict with
# the next invocation.
cleanup() {
    if [ -n "$JEKYLL_PID" ] && kill -0 "$JEKYLL_PID" 2>/dev/null; then
        kill "$JEKYLL_PID" 2>/dev/null || true
    fi
    pkill -P $$ 2>/dev/null || true
}
trap cleanup EXIT INT TERM

kill_previous_instances
start_jekyll

while true; do
    inotifywait -q -e modify,move,create,delete $CONFIG_FILE
    if [ $? -eq 0 ]; then
        echo "Change detected to $CONFIG_FILE, restarting Jekyll"
        if [ -n "$JEKYLL_PID" ] && kill -0 "$JEKYLL_PID" 2>/dev/null; then
            kill -KILL "$JEKYLL_PID" 2>/dev/null || true
        fi
        # Belt-and-suspenders for any other jekyll workers spawned by bundler.
        pkill -KILL -f 'jekyll serve' 2>/dev/null || true
        start_jekyll
    fi
done
