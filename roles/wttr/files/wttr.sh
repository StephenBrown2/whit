#!/bin/sh

curl -s https://wttr.in/"${1:-$(curl -s http://ip-api.com/json | jq -r 'if (.zip | length) != 0 then .zip else .city end')}"
