#!/usr/bin/env bats
#
# Tests for starship-ftl.plugin.zsh, the entry point a plugin manager sources.
# No starship binary needed.

setup() {
  # Keep every cached starship answer inside this test, not in the real cache.
  export XDG_CACHE_HOME="${BATS_TEST_TMPDIR}/cache"
  REPO="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  PLUGIN="${REPO}/starship-ftl.plugin.zsh"
}

zplug() {
  env -u STARSHIP_CONFIG -u FPATH zsh -fc "source ${PLUGIN} || exit 1
$1"
}

@test "sourcing the plugin defines both commands" {
  run zplug 'print "${+functions[ftl-prompt]}${+functions[ftl-transient]}"'
  [ "$output" = "11" ]
}

@test "sourcing the plugin puts completions on fpath" {
  run zplug 'print "${#${(@M)fpath:#'"${REPO}"'/completions}}"'
  [ "$output" = "1" ]
}

@test "sourcing twice does not duplicate the completions entry" {
  run zplug 'source '"${PLUGIN}"'
print "${#${(@M)fpath:#'"${REPO}"'/completions}}"'
  [ "$output" = "1" ]
}

@test "a completion exists for each command, named the way compinit expects" {
  # compinit picks these up by filename, so a rename silently loses completion.
  [ -f "${REPO}/completions/_ftl-prompt" ]
  [ -f "${REPO}/completions/_ftl-transient" ]
}

@test "each completion declares the command it completes" {
  run head -1 "${REPO}/completions/_ftl-prompt"
  [ "$output" = "#compdef ftl-prompt" ]
  run head -1 "${REPO}/completions/_ftl-transient"
  [ "$output" = "#compdef ftl-transient" ]
}

@test "the completions parse as zsh" {
  run zsh -n "${REPO}/completions/_ftl-prompt"
  [ "$status" -eq 0 ]
  run zsh -n "${REPO}/completions/_ftl-transient"
  [ "$status" -eq 0 ]
}

@test "the profile completion uses a function the plugin actually defines" {
  # The completion offers starship profiles by calling into the library. If that
  # name changes, completion silently falls back to no suggestions.
  run zplug 'print "${+functions[_ftl_transient_profile_names]}"'
  [ "$output" = "1" ]
  grep -q '_ftl_transient_profile_names' "${REPO}/completions/_ftl-transient"
}
