#!/usr/bin/env zsh
# ftl-prompt.zsh
#
# Draw the prompt before the rest of your .zshrc runs, then replace it once
# everything has loaded. Startup does the same work, it just stops making you
# wait to see something.
#
# At the very top of .zshrc:
#   path+=(/path/to/starship/bin)
#   source /path/to/starship-ftl.zsh
#   ftl-prompt starship
#
# By default the theme is loaded first and its own prompt is drawn, so what you
# see is what you get, with nothing to keep in sync. That costs a couple of
# milliseconds, which is the right trade for most themes.
#
# For a theme too slow to load up front, powerlevel10k and starship among them,
# -p draws an approximation immediately and loads the theme behind it:
#   ftl-prompt -p '%~ %# ' powerlevel10k
#
# With starship, -p's approximation can come out of the config instead, so there
# is only one prompt definition to keep in sync. -P draws the ftl-prompt profile:
#   ftl-prompt -P starship
#
#   # starship.toml
#   [profiles]
#   ftl-prompt = "$directory$character"
#
# Leave out of those anything that has to shell out, git especially, and the
# cost stays flat however big the repository is.
#
# Anything printed during startup, direnv and errors included, is captured and
# replayed above the real prompt once loading finishes.
#
# A cursor style set by a plugin or theme only takes effect once it loads,
# leaving the terminal's default cursor next to the drawn prompt until then.
# Set the style before calling ftl-prompt to apply it up front:
#   zstyle ':ftl-prompt:' cursor bar
# Styles are block, underline, or bar, with an optional blinking- prefix, or
# a raw DECSCUSR number 0-6.

0=${(%):-%N}
typeset -gUa fpath
fpath=(${0:A:h}/themes $fpath)
STARSHIP_FTL_VERSION="0.0.4"

(( $+functions[_ftl_cache_file] )) || source ${0:A:h}/ftl-cache.zsh
(( $+functions[_ftl_starship_render] )) || source ${0:A:h}/ftl-starship.zsh

autoload -Uz add-zsh-hook
zmodload -F zsh/files b:zf_rm b:zf_mkdir 2>/dev/null
zmodload -F zsh/system b:sysopen b:sysread 2>/dev/null

# promptinit normally declares these, and this does not run it.
typeset -ga prompt_theme
typeset -g prompt_newline=$'\n%{\r%}'

ftl-prompt() {
  _ftl_prompt_main "$@"
  local -i ret=$?

  # Check the hook regardless of $ret. A theme can fail after something was
  # already drawn, and that still has to be erased and still needs the options
  # below suspended until it is.
  (( ${precmd_functions[(I)_ftl_prompt_clear]} )) || return $ret

  # The drawn prompt leaves the cursor mid-line, and zsh would stamp a
  # PROMPT_EOL_MARK over it ahead of the first precmd. Suspend prompt_cr and
  # prompt_sp until the clear. That must outlive this function, which is why
  # it happens out here instead of under the emulate in _ftl_prompt_main.
  # The scroll before drawing keeps any partial line from a previous program
  # visible, which is most of what prompt_sp is for.
  typeset -ga _ftl_prompt_opts=()
  [[ -o prompt_cr ]] && _ftl_prompt_opts+=(prompt_cr)
  [[ -o prompt_sp ]] && _ftl_prompt_opts+=(prompt_sp)
  unsetopt localoptions prompt_cr prompt_sp
  return $ret
}

# Run a theme's setup function and apply the options it asks for, which is all
# `prompt` does that matters here. Unlike `prompt`, this returns the setup
# function's real status. Nothing scans fpath: run promptinit yourself afterwards
# if you want `prompt -l`, `prompt -p` or `prompt -r`.
_ftl_prompt_load_theme() {
  local theme=$1
  shift

  # Already defined by a plugin, or an autoload stub resolved off fpath at call
  # time. A theme with neither fails there, and zsh says so.
  (( $+functions[prompt_${theme}_setup] )) || autoload -Uz prompt_${theme}_setup

  # How a theme asks for prompt_* options.
  local -a prompt_opts=()

  prompt_theme=()
  prompt_${theme}_setup "$@" || return 1

  (( $#prompt_opts )) &&
      setopt noprompt{bang,cr,percent,sp,subst} "prompt${^prompt_opts[@]}"

  prompt_theme=($theme "$@")
  return 0
}

# No `emulate -L zsh` here or in _ftl_prompt_load_theme. It implies LOCAL_OPTIONS,
# which would roll back the setopt applying a theme's prompt_opts, losing `subst`
# and leaving starship's command-substitution PS1 displayed literally. The two
# prints that need prompt_subst scope it themselves.
_ftl_prompt_main() {
  local loading=
  local -i approximate=0 profiled=0 ret=0
  while [[ $1 == -* ]]; do
    case $1 in
      -p) loading=$2; approximate=1; shift 2 ;;
      -P) profiled=1; shift ;;
      --) shift; break ;;
      *)  return 1 ;;
    esac
  done

  if (( approximate && profiled )); then
    print -ru2 -- "ftl-prompt: -p draws a string and -P a profile, so use one or the other"
    return 1
  fi

  local theme=$1
  [[ -n $theme ]] || return 1
  shift

  if (( profiled )); then
    if [[ $theme != starship ]]; then
      print -ru2 -- "ftl-prompt: -P only works with the starship theme"
      return 1
    fi
    # Before rendering, so a profile is read out of the config the theme is
    # about to load rather than whichever one starship would default to.
    _ftl_starship_config $1
  fi

  # Drawing needs an interactive shell on a terminal that can save, restore and
  # erase. Without all of that, just set the theme the ordinary way.
  if [[ ! -o interactive || ! -o zle || ! -t 1 ]] ||
     ! zmodload zsh/terminfo 2>/dev/null ||
     (( ! (${+terminfo[sc]} && ${+terminfo[rc]} && ${+terminfo[ed]} && ${+terminfo[cuu]}) )); then
    _ftl_prompt_load_theme $theme "$@"
    return $?
  fi

  local cursor
  if zstyle -s ':ftl-prompt:' cursor cursor; then
    local -A cursors=(blinking-block 1 block 2 blinking-underline 3
                      underline 4 blinking-bar 5 bar 6)
    cursor=${cursors[$cursor]:-$cursor}
    [[ $cursor == <0-6> ]] && print -rn -- $'\e['$cursor' q'
  fi

  # Rendered before anything is on screen, so a config that cannot answer falls
  # back to the ordinary path with nothing to erase.
  local drawn=
  if (( profiled )); then
    if _ftl_prompt_profile_render; then
      drawn=$REPLY
    else
      profiled=0
    fi
  fi

  # Scroll now, before saving, so the saved position stays valid even when the
  # prompt lands at the bottom of the screen.
  print -n -- ${(pl.10..\n.)}
  echoti cuu 10
  echoti sc

  if (( profiled )); then
    _ftl_prompt_expand $drawn
    _ftl_prompt_capture
    # Same as -p below: what is on screen came from the config rather than the
    # theme, so a failing theme still needs the clear hook to erase it.
    _ftl_prompt_load_theme $theme "$@"
    ret=$?
  elif (( approximate )); then
    _ftl_prompt_expand $loading
    _ftl_prompt_capture
    # The approximation is already on screen, so a failing theme still needs the
    # clear hook below to erase it. Carry the status instead of returning here.
    _ftl_prompt_load_theme $theme "$@"
    ret=$?
  else
    # Nothing has been drawn yet, so a failing theme can bail out and leave the
    # shell with whatever prompt it already had.
    _ftl_prompt_load_theme $theme "$@" || return $?

    # The theme's precmd is what fills in the parts of PS1 that change, so run
    # it once before drawing. It runs again for the real prompt, which is the
    # price of not having a second prompt definition to maintain.
    (( $+functions[prompt_${theme}_precmd] )) && prompt_${theme}_precmd
    _ftl_prompt_expand $PS1
    _ftl_prompt_capture
  fi

  add-zsh-hook precmd _ftl_prompt_clear
  return $ret
}

# Draw a prompt string with prompt expansion applied. prompt_subst is needed
# because a theme's PS1 is mostly parameters, and starship's is a command
# substitution. Scoped to this function so it cannot leak into the shell or
# collide with the options a theme asked for.
_ftl_prompt_expand() {
  emulate -L zsh
  setopt prompt_subst
  print -Pnr -- $1
}

# Sets REPLY to the ftl-prompt profile, rendered out of the starship config the
# theme is about to load. Non-zero means it could not, and the caller draws the
# theme's own prompt instead. Warnings go to the terminal rather than into the
# captured startup output, which is the last place a user would think to look.
_ftl_prompt_profile_render() {
  emulate -L zsh
  typeset -g REPLY=

  (( $+commands[starship] )) || {
    print -ru2 -- "ftl-prompt: starship not found in path"
    return 1
  }

  # Checked against the table rather than trusted to fail: `starship prompt
  # --profile bogus` exits 0 and prints, so a typo would draw silent nonsense.
  if ! _ftl_starship_profile_exists ftl-prompt; then
    print -ru2 -- "ftl-prompt: no starship profile 'ftl-prompt', drawing the real prompt"
    print -ru2 -- "ftl-prompt: add [profiles] to your starship.toml"
    return 1
  fi

  # The blank line add_newline puts above it stays, because the real prompt
  # replacing this one gets it too.
  REPLY=$(_ftl_starship_render ftl-prompt)
  return 0
}

# Does captured output take up any room on screen?
_ftl_prompt_visible() {
  emulate -L zsh
  setopt extended_glob
  [[ -n ${${1//$'\e'(\][^$'\a']#$'\a'|\[[0-9;?]#[[:alpha:]]|\(?|?)/}//[[:space:]]/} ]]
}

# Send startup output to a log, unlinked at once so nothing can be left behind,
# to replay above the real prompt instead of being erased with the drawn one.
_ftl_prompt_capture() {
  emulate -L zsh

  # 700 because /tmp is shared when TMPDIR is unset; a foreign dir fails the open.
  local dir=${${TMPDIR:-/tmp}%/}/starship-ftl
  [[ -d $dir ]] || _ftl_prompt_mkdir $dir

  # Opened here rather than left to exec, where a failing redirect takes stdout.
  local log=$dir/log.$$
  { : >| $log } 2>/dev/null || return 0

  # No way to read it back means nothing to replay, so do not capture at all.
  if (( $+builtins[sysread] )) && sysopen -r -u _ftl_prompt_rfd $log 2>/dev/null; then
    exec {_ftl_prompt_fd1}>&1 {_ftl_prompt_fd2}>&2 >>$log 2>&1
  fi
  _ftl_prompt_unlink $log
}

# Both prefer the zsh/files builtin, which does the work without a fork.
_ftl_prompt_unlink() {
  if (( $+builtins[zf_rm] )); then
    zf_rm -f -- $1 2>/dev/null
  else
    command rm -f -- $1 2>/dev/null
  fi
  return 0
}

_ftl_prompt_mkdir() {
  if (( $+builtins[zf_mkdir] )); then
    zf_mkdir -m 700 -p -- $1 2>/dev/null
  else
    command mkdir -m 700 -p -- $1 2>/dev/null
  fi
  return 0
}

_ftl_prompt_clear() {
  # Put prompt_cr and prompt_sp back out here. Options set under an emulate
  # -L roll back to their function-entry state on return, so the emulate
  # lives in an inner function and the restore stays outside it.
  (( ${#_ftl_prompt_opts[@]} )) && setopt -- "${_ftl_prompt_opts[@]}"

  () {
    emulate -L zsh
    add-zsh-hook -d precmd _ftl_prompt_clear

    if (( ${+_ftl_prompt_fd1} )); then
      exec 1>&$_ftl_prompt_fd1 2>&$_ftl_prompt_fd2 \
          {_ftl_prompt_fd1}>&- {_ftl_prompt_fd2}>&-
    fi

    # Back to where the drawn prompt started, wipe from there down, and lay
    # the replayed startup output in its place. One write, inside a synchronized
    # update, so the terminal never paints the blank in-between state. The real
    # prompt then lands below the replay.
    local replay= chunk=
    if (( ${+_ftl_prompt_rfd} )); then
      # Never read from, so it sits at the start already. No seek needed.
      while sysread -i $_ftl_prompt_rfd chunk 2>/dev/null; do replay+=$chunk; done
      exec {_ftl_prompt_rfd}>&-

      # sysread keeps the trailing newlines `$(<file)` used to drop.
      setopt extended_glob
      replay=${replay%%$'\n'##}
      [[ -n $replay ]] && _ftl_prompt_visible $replay && replay+=$'\n'
    fi
    print -rn -- $'\e[?2026h'${terminfo[rc]}${terminfo[sgr0]}${terminfo[ed]}${replay}

    # PS1 is expanded after every precmd hook, and starship's runs a command
    # substitution, so ending the update here would show the erase on its own.
    _ftl_prompt_sync_defer || print -rn -- $'\e[?2026l'

    unset _ftl_prompt_rfd _ftl_prompt_fd1 _ftl_prompt_fd2 _ftl_prompt_opts
    unfunction _ftl_prompt_clear
  }
}

# zle-line-init runs with the real prompt already painted, so that is where the
# update ends. `zle -F` on a descriptor that is always readable backs it up, for
# a plugin that rebinds the widget out from under us.
_ftl_prompt_sync_defer() {
  emulate -L zsh
  local -i deferred=0

  # Without zsh/zutil loaded, add-zle-hook-widget silently registers nothing.
  autoload -Uz add-zle-hook-widget
  zmodload zsh/zutil 2>/dev/null &&
    add-zle-hook-widget zle-line-init _ftl_prompt_sync_end 2>/dev/null && deferred=1

  typeset -gi _ftl_prompt_sfd=0
  if (( $+builtins[sysopen] )) &&
     sysopen -r -o cloexec -u _ftl_prompt_sfd /dev/null 2>/dev/null; then
    if zle -F $_ftl_prompt_sfd _ftl_prompt_sync_end 2>/dev/null; then
      deferred=1
    else
      exec {_ftl_prompt_sfd}>&-
      _ftl_prompt_sfd=0
    fi
  fi

  (( deferred )) || _ftl_prompt_sync_cleanup
  return $(( ! deferred ))
}

# Ends the update the clear opened, so the erase and the redraw arrive together.
_ftl_prompt_sync_end() {
  emulate -L zsh
  print -rn -- $'\e[?2026l'
  _ftl_prompt_sync_cleanup
  return 0
}

# Both go at once, so whichever did not run cannot fire on a restored shell.
_ftl_prompt_sync_cleanup() {
  emulate -L zsh
  add-zle-hook-widget -d zle-line-init _ftl_prompt_sync_end 2>/dev/null

  if (( ${_ftl_prompt_sfd:-0} )); then
    zle -F $_ftl_prompt_sfd 2>/dev/null
    exec {_ftl_prompt_sfd}>&-
  fi
  unset _ftl_prompt_sfd
  return 0
}
