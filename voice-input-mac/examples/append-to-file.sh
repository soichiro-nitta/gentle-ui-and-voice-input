#!/bin/sh
# 送り先のコマンドの見本：文字にしたもの（標準入力）を、時刻つきでメモのファイルに足す。
# 置き場所は VOICE_INPUT_NOTES で変えられる。
set -eu
notes="${VOICE_INPUT_NOTES:-$HOME/Documents/voice-input-notes.md}"
mkdir -p "$(dirname "$notes")"
text="$(cat)"
printf -- '- %s %s\n' "$(date '+%Y-%m-%d %H:%M')" "$text" >> "$notes"
