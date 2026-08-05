#!/usr/bin/env zsh
# ftl-transient.zsh
#
# Replace the prompt on a finished command line with a short one, so scrollback
# reads as a list of commands instead of a wall of prompts. The full prompt only
# ever appears on the line you are editing.
#
# Starship has no transient prompt on Zsh. It does have profiles, which is the
# rendering half:
#   # starship.toml
#   [profiles]
#   transient = "[❯](bold green) "
#
# Then, after your prompt is set up:
#   source /path/to/ftl-transient.zsh
#   ftl-transient on
#
# And to turn it back off:
#   ftl-transient off
#
# The profile defaults to "transient". Pass another name to use a different one:
#   ftl-transient on my-short-prompt
#
# Only the left prompt is touched. Whether a finished line keeps its right prompt
# is zsh's own transient_rprompt, which is the user's to set either way.
#
# How it works. Four moving parts, in the order they run:
#
#   precmd            Render the short prompt and cache it, one starship call
#                     per command. Nothing shells out later, so no process spawn
#                     sits between a keypress and the redraw.
#   zle-line-finish   The line is done. Draw the cached string where the prompt
#                     was, so the line as committed to scrollback keeps the short
#                     prompt.
#   zle-line-init     A real prompt has just been drawn, so there is nothing left
#                     to undo. Stands the restore below down.
#   zle -F            Redraw the real prompt, deferred, unless line-init already
#                     did. sysopen on /dev/null gives a descriptor that is always
#                     readable, so the handler fires the moment zle is next
#                     active: after the line is committed, before the next one is
#                     edited.
#
# The swap is a redraw, not an assignment. `PROMPT=$short zle .reset-prompt` is a
# command-prefix assignment, so it lasts only as long as that one command. PROMPT
# is never modified, so there is nothing to snapshot and a prompt set later by
# anything else is left alone.
#
# The deferral is why the swap is safe. zle-line-finish also fires for lines that
# were abandoned rather than run, so the prompt sometimes shortens when it should
# not have. Instead of enumerating those cases, the restore is armed at the same
# moment the prompt shortens, and undoes it whenever nothing else already has.
#
# Ctrl-C never reaches the send-break widget, it arrives as SIGINT, so both paths
# are covered: a TRAPINT for the signal and a send-break wrapper for the widget.
# Both delegate to whatever was already installed rather than replacing it.

zmodload zsh/system || return 1
zmodload zsh/parameter 2>/dev/null || return 1
# add-zle-hook-widget needs zsh/zutil already loaded. It keeps its list of valid
# hook names in a zstyle, and on a first call with the module absent it rejects
# every hook name and registers nothing, silently. zstyle on its own works
# without this; add-zle-hook-widget does not.
zmodload zsh/zutil || return 1
autoload -Uz add-zsh-hook add-zle-hook-widget

0=${(%):-%N}
(( $+functions[_ftl_cache_file] )) || source ${0:A:h}/ftl-cache.zsh

typeset -g  _ftl_transient_profile=
typeset -g  _ftl_transient_prompt=
typeset -gi _ftl_transient_fd=0
typeset -gi _ftl_transient_active=0
# Set when the short prompt is on screen, cleared once anything else has drawn
# over it. The deferred restore only has work to do while this is set.
typeset -gi _ftl_transient_stale=0

ftl-transient() {
  case $1 in
    on)
      shift
      _ftl_transient_enable "$@" || return
      return 0
      ;;
    off)
      _ftl_transient_disable
      return 0
      ;;
    *)
      print -ru2 -- "usage: ftl-transient on [profile]"
      print -ru2 -- "       ftl-transient off"
      return 1
      ;;
  esac
}

_ftl_transient_enable() {
  emulate -L zsh

  # Guards activation, not the definitions in this file, so sourcing it is always
  # safe and always defines its functions.
  [[ -o interactive ]] || return 0

  (( _ftl_transient_active )) && return 0
  (( $+commands[starship] )) || {
    print -ru2 -- "ftl-transient: starship not found in path"
    return 1
  }

  local profile=${1:-transient}

  # Check the profile once here, so a typo produces one clear message instead of
  # a silently empty prompt on every command from now on.
  if _ftl_transient_profile_exists $profile; then
    _ftl_transient_profile=$profile
  else
    print -ru2 -- "ftl-transient: no starship profile '$profile', using '%# '"
    print -ru2 -- "ftl-transient: add [profiles] to your starship.toml"
    _ftl_transient_profile=
  fi

  add-zsh-hook precmd _ftl_transient_precmd
  add-zle-hook-widget zle-line-finish _ftl_transient_truncate
  add-zle-hook-widget zle-line-init _ftl_transient_fresh
  _ftl_transient_wrap_send_break
  _ftl_transient_active=1
}

_ftl_transient_disable() {
  (( _ftl_transient_active )) || return 0

  add-zsh-hook -d precmd _ftl_transient_precmd
  add-zle-hook-widget -d zle-line-finish _ftl_transient_truncate 2>/dev/null
  add-zle-hook-widget -d zle-line-init _ftl_transient_fresh 2>/dev/null
  _ftl_transient_unwrap_send_break

  # Hand back a zle-line-finish we took over from another plugin.
  if [[ ${widgets[zle-line-finish]:-} == user:_ftl_transient_line_finish ]] &&
     (( ${+widgets[._ftl_transient_orig::zle-line-finish]} )); then
    zle -A ._ftl_transient_orig::zle-line-finish zle-line-finish
    zle -D ._ftl_transient_orig::zle-line-finish
  fi

  # Only remove a TRAPINT that is ours. The chain is built in precmd, so before
  # the first one any trap sitting there belongs to someone else.
  if (( $+functions[_ftl_transient_orig_trapint] )); then
    functions[TRAPINT]=${functions[_ftl_transient_orig_trapint]}
    unfunction _ftl_transient_orig_trapint
  elif (( $+functions[TRAPINT] )) &&
       [[ ${functions[TRAPINT]} == *_ftl_transient_truncate* ]]; then
    unfunction TRAPINT
  fi

  # `zle -F fd` only drops the handler, so close the descriptor too or it stays
  # open for the life of the shell, one per on/off cycle.
  (( _ftl_transient_fd )) && {
    zle -F $_ftl_transient_fd 2>/dev/null
    exec {_ftl_transient_fd}>&-
    _ftl_transient_fd=0
  }

  # PROMPT was never assigned to, so there is nothing to put back.
  _ftl_transient_stale=0
  _ftl_transient_active=0
}

# One starship call per command, here rather than in the widget. Rendering in
# the widget would put a process spawn between the keypress and the redraw.
_ftl_transient_precmd() {
  # No `emulate -L zsh` at this level: it implies LOCAL_TRAPS, which drops the
  # TRAPINT below as soon as this function returns. The emulate lives in the
  # inner function so the trap definition stays outside its scope.
  () {
    emulate -L zsh

    if [[ -n $_ftl_transient_profile ]]; then
      _ftl_transient_prompt=$(_ftl_transient_render $_ftl_transient_profile)
    else
      _ftl_transient_prompt='%# '
    fi
  }

  _ftl_transient_repair_line_finish

  # Preserve a TRAPINT someone else installed; ours has to run to catch Ctrl-C,
  # which arrives as a signal and never reaches send-break. Every cycle rather
  # than once at enable, so a trap installed later still gets chained. The guard
  # stops ours being captured as the original and nesting each cycle in the last.
  if (( $+functions[TRAPINT] )) &&
     [[ ${functions[TRAPINT]} != *_ftl_transient_truncate* ]]; then
    functions[_ftl_transient_orig_trapint]=${functions[TRAPINT]}
  fi

  # Redefined every cycle so it survives anything that clears traps, and so it
  # is present from the first prompt onward.
  TRAPINT() {
    zle && _ftl_transient_truncate
    if (( $+functions[_ftl_transient_orig_trapint] )); then
      _ftl_transient_orig_trapint "$@"
      return $?
    fi
    return $(( 128 + $1 ))
  }
}

# Sets reply to the profile names. An array, not stdout, so the cache hit forks
# nothing, which is the whole point of it.
_ftl_transient_profile_load() {
  emulate -L zsh

  if (( $+functions[_ftl_cache_file] )) &&
     _ftl_cache_file starship-profiles _ftl_transient_profile_names_live; then
    _ftl_cache_lines $REPLY
    return 0
  fi

  typeset -ga reply=(${(f)"$(_ftl_transient_profile_names_live)"})
  return 0
}

# One name per line, for the completion and for the cache.
_ftl_transient_profile_names() {
  emulate -L zsh
  local -a reply
  _ftl_transient_profile_load
  (( $#reply )) && print -rl -- $reply
  return 0
}

# Read the table rather than rendering a profile: `prompt --profile bogus` exits
# 0 and prints, so a typo is indistinguishable from a working one.
_ftl_transient_profile_names_live() {
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

_ftl_transient_profile_exists() {
  emulate -L zsh
  local -a reply
  _ftl_transient_profile_load

  # (Ie) is an exact string match, so a profile name is never read as a pattern.
  (( ${reply[(Ie)$1]} ))
}

# add_newline defaults to true and applies to profile output as well, which
# would leave a blank line above every committed command. Strip leading
# newlines rather than making every user set add_newline = false.
_ftl_transient_render() {
  emulate -L zsh
  local out
  # STARSHIP_SHELL is what tells starship to double a literal % and to wrap escape
  # sequences in %{ %}, both of which PROMPT needs. `starship init zsh` exports it,
  # but this renders for PROMPT either way, so do not depend on that having run.
  out=$(STARSHIP_SHELL=zsh starship prompt --profile $1 \
          --terminal-width="$COLUMNS" \
          --status="${STARSHIP_CMD_STATUS:-0}" \
          --pipestatus="${STARSHIP_PIPE_STATUS[*]:-}" \
          --cmd-duration="${STARSHIP_DURATION:-0}" \
          --jobs="${STARSHIP_JOBS_COUNT:-0}" \
          --keymap="${KEYMAP:-}" 2>/dev/null)
  # Not ${out##$'\n'##}: the `##` repeat operator needs EXTENDED_GLOB, which
  # the emulate above turns off, so that form silently strips nothing.
  while [[ $out == $'\n'* ]]; do
    out=${out#$'\n'}
  done
  print -rn -- $out
}

_ftl_transient_truncate() {
  emulate -L zsh
  # prompt_subst for the same reason ftl-prompt needs it: the prompt being
  # restored later is built from parameters and a command substitution.
  setopt local_options prompt_subst

  # Arm the deferred restore before redrawing, once per cycle.
  (( ! _ftl_transient_fd )) && {
    sysopen -r -o cloexec -u _ftl_transient_fd /dev/null
    zle -F $_ftl_transient_fd _ftl_transient_restore
  }

  # TRAPINT can reach here with the editor already gone.
  zle || return 0
  _ftl_transient_stale=1
  # Command-prefix assignment, so it lasts only as long as this reset-prompt and
  # nothing downstream has to put PROMPT back.
  PROMPT=$_ftl_transient_prompt zle .reset-prompt
  zle -R
}

# Called by `zle -F` with the file descriptor as $1.
_ftl_transient_restore() {
  emulate -L zsh
  setopt local_options prompt_subst

  exec {1}>&-
  (( ${+1} )) && zle -F $1
  _ftl_transient_fd=0

  # Only the screen goes stale, never PROMPT. On the ordinary path line-init has
  # already redrawn by now, so this would be a second render of a correct prompt.
  (( _ftl_transient_stale )) || return 0
  _ftl_transient_stale=0
  zle .reset-prompt
  zle -R
}

# A fresh prompt has just been drawn, so whatever the truncation put on screen is
# gone and the deferred restore has nothing left to undo.
_ftl_transient_fresh() {
  _ftl_transient_stale=0
}

# A bare `zle -N zle-line-finish` replaces add-zle-hook-widget's dispatcher,
# leaving us in its chain but never called. Re-checked every precmd because
# plugins load in whatever order the user's manager picks.
_ftl_transient_repair_line_finish() {
  case ${widgets[zle-line-finish]:-} in
    user:azhw:zle-line-finish|user:_ftl_transient_line_finish) return 0 ;;
    # add-zle-hook-widget never took, so let it retry.
    '') add-zle-hook-widget zle-line-finish _ftl_transient_truncate 2>/dev/null
        return 0 ;;
  esac

  # Someone else owns it. Delegate to their binding instead of dropping it.
  zle -A zle-line-finish ._ftl_transient_orig::zle-line-finish
  zle -N zle-line-finish _ftl_transient_line_finish
}

_ftl_transient_line_finish() {
  _ftl_transient_truncate
  (( ${+widgets[._ftl_transient_orig::zle-line-finish]} )) &&
    zle ._ftl_transient_orig::zle-line-finish -f nolast -N -- "$@"
  return 0
}

# send-break is a real widget, not a hook, so it cannot go through
# add-zle-hook-widget. Never replace it outright: `zle -N send-break mine`
# deletes whatever a plugin already installed, and calling `zle .send-break`
# afterwards skips their wrapper for good. Alias the existing binding to a
# private name and delegate to that instead.
_ftl_transient_wrap_send_break() {
  # send-break always exists, reading as `builtin` when nobody has rebound it,
  # so there is no unbound case needing a widget created from scratch.
  case ${widgets[send-break]} in
    user:_ftl_transient_send_break) ;;
    *)
      zle -A send-break ._ftl_transient_orig::send-break
      zle -N send-break _ftl_transient_send_break
      typeset -g _ftl_transient_break_wrapped=1
      ;;
  esac
}

_ftl_transient_unwrap_send_break() {
  (( ${+_ftl_transient_break_wrapped} )) || return 0
  zle -A ._ftl_transient_orig::send-break send-break
  zle -D ._ftl_transient_orig::send-break
  unset _ftl_transient_break_wrapped
}

_ftl_transient_send_break() {
  _ftl_transient_truncate
  if (( ${+widgets[._ftl_transient_orig::send-break]} )); then
    zle ._ftl_transient_orig::send-break -- "$@"
  else
    zle .send-break
  fi
}
