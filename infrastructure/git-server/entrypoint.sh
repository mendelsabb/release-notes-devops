#!/bin/sh
set -eu
repo=/srv/git/release-notes.git
if [ ! -f "$repo/HEAD" ]; then
  git init --quiet --bare --initial-branch=main "$repo"
  git -C "$repo" config http.receivepack true
fi
spawn-fcgi -s /tmp/fcgiwrap.sock -M 0600 -- /usr/bin/fcgiwrap
exec nginx -c /etc/nginx/git.conf -g 'daemon off;'
