#!/usr/bin/env bats
#
# Tests for the drawing, which every other file has to skip: bats runs with
# stdout on a pipe, so ftl-prompt takes its non-drawing branch there. zsh/zpty
# supplies a terminal, and these assert on the bytes written to it.
#
# The stream comes back with the synchronized-update marks as <SYNC-ON> and
# <SYNC-OFF>, and every other escape as <ESC>, so a failure prints legibly.

setup() {
  if ! command -v starship >/dev/null 2>&1; then
    skip "starship is not installed"
  fi
  if ! zsh -fc 'zmodload zsh/zpty' 2>/dev/null; then
    skip "zsh/zpty is not available"
  fi

  REPO="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  ZD="${BATS_TEST_TMPDIR}/zdot"
  mkdir -p "$ZD"

  # plain.toml renders FULL> and no modules, so the bytes are the same anywhere.
  cat > "${ZD}/.zshrc" <<EOF
export STARSHIP_CONFIG=${BATS_TEST_DIRNAME}/fixtures/plain.toml
source ${REPO}/ftl-prompt.zsh
ftl-prompt starship
EOF

  cat > "${BATS_TEST_TMPDIR}/capture.zsh" <<'EOF'
emulate -L zsh
zmodload zsh/zpty || exit 2

typed=$1
# A substring, not a pattern. The default is full of glob characters.
want=${2:-$'\e[?2026l'}

zpty ftl 'zsh --no-globalrcs -i'
# Written before the first prompt, so the key is already waiting when zle starts.
[[ -n $typed ]] && zpty -w ftl $typed

out= chunk=
integer i
for (( i = 0; i < 100; i++ )); do
  if zpty -rt ftl chunk 2>/dev/null; then
    out+=$chunk
    [[ $out == *$want* ]] && break
  else
    sleep 0.05
  fi
done
zpty -d ftl 2>/dev/null

out=${out//$'\e[?2026h'/<SYNC-ON>}
out=${out//$'\e[?2026l'/<SYNC-OFF>}
print -r -- ${out//$'\e'/<ESC>}
EOF
}

# $1: a line to type ahead of the first prompt. $2: text to read until,
# defaulting to the end of the synchronized update.
capture() {
  env -u STARSHIP_CONFIG -u FPATH PATH="$PATH" HOME="$HOME" \
      ZDOTDIR="$ZD" TERM=xterm-256color \
      zsh -f "${BATS_TEST_TMPDIR}/capture.zsh" "${1:-}" "${2:-}"
}

count() {
  printf '%s' "$1" | grep -o -- "$2" | wc -l | tr -d ' '
}

@test "the drawn prompt is erased and the real one painted in one frame" {
  # starship runs between the erase and the paint, so ending the update at the
  # erase hands the terminal that gap as a frame of its own. The flicker.
  run capture
  [ "$status" -eq 0 ]
  [ "$(count "$output" '<SYNC-ON>')" = "1" ]
  [ "$(count "$output" '<SYNC-OFF>')" = "1" ]

  frame="${output#*<SYNC-ON>}"
  frame="${frame%%<SYNC-OFF>*}"
  [[ "$frame" == *"FULL>"* ]]
}

@test "the frame is closed with a key already waiting" {
  # zle reads it rather than going idle, so the `zle -F` backstop never fires.
  run capture exit
  [ "$status" -eq 0 ]
  [ "$(count "$output" '<SYNC-OFF>')" = "1" ]
}

@test "the frame is closed when a plugin rebinds zle-line-init after us" {
  # A rebind from .zshrc is harmless, ours goes on in precmd afterwards. From a
  # precmd hook ordered after ours it drops us, leaving only the backstop.
  cat >> "${ZD}/.zshrc" <<'EOF'
autoload -Uz add-zsh-hook
foreign_init() { : }
_foreign_precmd() { zle -N zle-line-init foreign_init }
add-zsh-hook precmd _foreign_precmd
EOF
  run capture
  [ "$status" -eq 0 ]
  [ "$(count "$output" '<SYNC-OFF>')" = "1" ]
}

@test "nothing of the drawing is left behind once the prompt is up" {
  # Typed rather than sourced, so it runs after the first precmd. Reading until
  # cr=on: the echoed command line matches hook= before any of it has run.
  local report='print -r -- "hook=${#${(@M)precmd_functions:#_ftl_prompt_clear}} sfd=${+_ftl_prompt_sfd} log=${+_ftl_prompt_log} cr=${options[promptcr]} sp=${options[promptsp]}"'
  run capture "$report" 'cr=on'
  [ "$status" -eq 0 ]
  [[ "$output" == *"hook=0 sfd=0 log=0 cr=on sp=on"* ]]
}
