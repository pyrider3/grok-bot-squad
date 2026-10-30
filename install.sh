#!/bin/sh
set -eu
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
target_dir="${XDG_CONFIG_HOME:-$HOME/.config}/noctalia/plugins/grok-bot"
if [ -d "$target_dir" ]; then
    backup_dir="$target_dir.backup-$(date +%Y%m%d-%H%M%S)"
    cp -R "$target_dir" "$backup_dir"
    printf 'Backup: %s\n' "$backup_dir"
fi
mkdir -p "$target_dir"
cp -R "$source_dir/plugin/." "$target_dir/"
printf 'Installed: %s\nEnable Grok Bot in your shell plugin settings.\n' "$target_dir"
