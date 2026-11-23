#!/bin/sh
printf '\033c\033]0;%s\a' SPAAAAAAAAAACE
base_path="$(dirname "$(realpath "$0")")"
"$base_path/SPAAAAAAAAAACE.x86_64" "$@"
