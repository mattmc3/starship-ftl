#!/usr/bin/env bats
#
# The only tests that use the fake starship.
#
# Real starship renders a prompt without reporting which arguments it got, so a
# fake is the only way to check that status, duration, jobs, keymap and terminal
# width are still forwarded. Those feed modules like $status and $cmd_duration,
# and a transient prompt using them renders wrong if they stop being passed.
#
# Anything else about starship's behavior belongs in ftl-transient.bats,
# against the real binary.

setup() {
  REPO="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  LIB="${REPO}/ftl-transient.zsh"
  FAKEBIN="${BATS_TEST_DIRNAME}/fixtures/bin"
  chmod +x "${FAKEBIN}/starship"
}

zfake() {
  PATH="${FAKEBIN}:${PATH}" zsh -fc "source ${LIB} || exit 1
$1"
}

@test "render forwards the profile name" {
  run zfake '_ftl_transient_render someprofile'
  [[ "$output" == *"P:someprofile"* ]]
}

@test "render forwards status, duration and jobs from starship's own variables" {
  run zfake 'STARSHIP_CMD_STATUS=42 STARSHIP_DURATION=1234 STARSHIP_JOBS_COUNT=7 _ftl_transient_render p'
  [[ "$output" == *"s:42"* ]]
  [[ "$output" == *"d:1234"* ]]
  [[ "$output" == *"j:7"* ]]
}

@test "render defaults status, duration and jobs when those are unset" {
  run zfake '_ftl_transient_render p'
  [[ "$output" == *"s:0"* ]]
  [[ "$output" == *"d:0"* ]]
  [[ "$output" == *"j:0"* ]]
}

@test "render forwards the keymap so a vi-mode character module works" {
  run zfake 'KEYMAP=vicmd _ftl_transient_render p'
  [[ "$output" == *"k:vicmd"* ]]
}

@test "render forwards the terminal width" {
  run zfake 'COLUMNS=137 _ftl_transient_render p'
  [[ "$output" == *"w:137"* ]]
}

@test "enabling without starship on PATH fails with a message" {
  # PATH has to be emptied inside zsh. Doing it outside makes the shell itself
  # unfindable, and the test passes without reaching the enable path.
  local zsh_bin
  zsh_bin="$(command -v zsh)"
  run bash -c "'${zsh_bin}' -fic 'source ${LIB}; PATH=/nonexistent; hash -r; ftl-transient on; print \"rc=\$?\"' 2>&1"
  [[ "$output" == *"starship not found"* ]]
  [[ "$output" == *"rc=1"* ]]
}
