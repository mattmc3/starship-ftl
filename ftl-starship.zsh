#!/usr/bin/env zsh
# ftl-starship.zsh
#
# What ftl-prompt, ftl-transient and the starship theme all need from starship:
# where the config lives, which profiles it defines, and how to render one.
#
# Kept apart from the three so none of them has to load the others, and so the
# config a profile renders against is resolved the same way wherever it is asked
# for.

0=${(%):-%N}
(( $+functions[_ftl_cache_file] )) || source ${0:A:h}/ftl-cache.zsh

# Point STARSHIP_CONFIG at a named config, if one of the usual places has it.
# The name is either a path to a .toml or a bare name to look up.
# (N-.) => null glob, follow symlinks, match files
_ftl_starship_config() {
  emulate -L zsh
  [[ -n $1 ]] || return 0

  local -a configs=(
    "$1"(N-.)
    "${ZDOTDIR:-${XDG_CONFIG_HOME:-$HOME/.config}/zsh}/themes/${1}.toml"(N-.)
    "${XDG_CONFIG_HOME:-$HOME/.config}/starship/${1}.toml"(N-.)
  )
  (( $#configs )) && export STARSHIP_CONFIG=$configs[1]
  return 0
}

# Sets reply to the profile names. An array, not stdout, so the cache hit forks
# nothing, which is the whole point of it.
_ftl_starship_profile_load() {
  emulate -L zsh

  if (( $+functions[_ftl_cache_file] )) &&
     _ftl_cache_file starship-profiles _ftl_starship_profile_names_live; then
    _ftl_cache_lines $REPLY
    return 0
  fi

  typeset -ga reply=(${(f)"$(_ftl_starship_profile_names_live)"})
  return 0
}

# One name per line, for the completion and for the cache.
_ftl_starship_profile_names() {
  emulate -L zsh
  local -a reply
  _ftl_starship_profile_load
  (( $#reply )) && print -rl -- $reply
  return 0
}

# Read the table rather than rendering a profile: `prompt --profile bogus` exits
# 0 and prints, so a typo is indistinguishable from a working one.
_ftl_starship_profile_names_live() {
  emulate -L zsh
  local line key

  for line in ${(f)"$(starship print-config profiles 2>/dev/null)"}; do
    [[ $line == *=* ]] || continue
    key=${line%%=*}
    key=${key//[[:space:]]/}
    key=${key//[\"\']/}
    print -r -- $key
  done
  return 0
}

_ftl_starship_profile_exists() {
  emulate -L zsh
  local -a reply
  _ftl_starship_profile_load

  # (Ie) is an exact string match, so a profile name is never read as a pattern.
  (( ${reply[(Ie)$1]} ))
}

# Render a profile for PROMPT. STARSHIP_SHELL is what tells starship to double a
# literal % and to wrap escape sequences in %{ %}, both of which PROMPT needs.
# `starship init zsh` exports it, but this renders for PROMPT either way, so do
# not depend on that having run.
#
# A second argument of `oneline` drops the blank line add_newline puts above the
# output, for a caller drawing onto a line that is already there.
_ftl_starship_render() {
  emulate -L zsh
  local out
  out=$(STARSHIP_SHELL=zsh starship prompt --profile $1 \
          --terminal-width="$COLUMNS" \
          --status="${STARSHIP_CMD_STATUS:-0}" \
          --pipestatus="${STARSHIP_PIPE_STATUS[*]:-}" \
          --cmd-duration="${STARSHIP_DURATION:-0}" \
          --jobs="${STARSHIP_JOBS_COUNT:-0}" \
          --keymap="${KEYMAP:-}" 2>/dev/null)

  # Not ${out##$'\n'##}: the `##` repeat operator needs EXTENDED_GLOB, which
  # the emulate above turns off, so that form silently strips nothing.
  if [[ $2 == oneline ]]; then
    while [[ $out == $'\n'* ]]; do
      out=${out#$'\n'}
    done
  fi
  print -rn -- $out
}
