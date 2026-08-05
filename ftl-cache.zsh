#!/usr/bin/env zsh
# ftl-cache.zsh
#
# Cache what starship tells us, so only the first shell pays for it. Every
# starship call is a process spawn, and those are most of what this costs.
#
# Keyed on the mtime and size of the starship binary and the config, so editing
# a config invalidates it next shell. A config whose mtime survives the edit,
# restored from a backup or copied with `cp -p`, is the case that slips past.
#
#   rm -rf ${XDG_CACHE_HOME:-~/.cache}/starship-ftl   recover from a stale one
#   zstyle ':starship-ftl:' cache no                  opt out, run everything live

# Bump when the shape of a cached file changes, so old files miss.
typeset -g _FTL_CACHE_VERSION=1

zmodload -F zsh/stat b:zstat 2>/dev/null

# Sets REPLY to everything that can change a cached answer. Not a command
# substitution: a fork here would cost more than the cached call saves.
_ftl_cache_stamp() {
  emulate -L zsh
  (( $+builtins[zstat] )) || return 1

  local -A st
  local input
  local -a inputs=(
    ${commands[starship]}
    ${STARSHIP_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/starship.toml}
  )

  typeset -g REPLY="v$_FTL_CACHE_VERSION"
  for input in $inputs; do
    # A missing config has to read differently from one that exists, or
    # creating one would not invalidate anything.
    if zstat -H st -- $input 2>/dev/null; then
      REPLY+=" $input:$st[mtime]:$st[size]"
    else
      REPLY+=" $input:-"
    fi
  done
  return 0
}

# Sets REPLY to a cache file holding $2's output, refreshed when the stamp no
# longer matches. Non-zero means the caller has to run the command live. The
# stamp is the first line, commented so the file stays sourceable.
_ftl_cache_file() {
  emulate -L zsh
  local name=$1 generator=$2

  zstyle -T ':starship-ftl:' cache || return 1
  _ftl_cache_stamp || return 1

  local stamp=$REPLY
  local dir=${XDG_CACHE_HOME:-$HOME/.cache}/starship-ftl
  local file=$dir/$name.zsh

  # Read only the first line on a hit. The body is for whoever asked for it.
  if [[ -s $file ]]; then
    local head=
    read -r head < $file 2>/dev/null
    if [[ $head == "# $stamp" ]]; then
      typeset -g REPLY=$file
      return 0
    fi
  fi

  [[ -d $dir ]] || mkdir -p $dir 2>/dev/null || return 1

  local body
  body=$($generator) || return 1

  # Write somewhere else and rename, so a shell starting while this one writes
  # reads either the whole old file or the whole new one.
  local tmp=$file.$$
  if ! { print -r -- "# $stamp"; print -r -- $body } >| $tmp 2>/dev/null; then
    command rm -f -- $tmp 2>/dev/null
    return 1
  fi
  if ! command mv -f -- $tmp $file 2>/dev/null; then
    command rm -f -- $tmp 2>/dev/null
    return 1
  fi

  typeset -g REPLY=$file
  return 0
}

# Sets reply to the cache file's lines, minus the stamp. `$(<file)` is read by
# the shell, so no spawn, which a command substitution would cost.
_ftl_cache_lines() {
  emulate -L zsh
  local -a lines=(${(f)"$(<$1)"})
  typeset -ga reply=(${lines[2,-1]})
  return 0
}
