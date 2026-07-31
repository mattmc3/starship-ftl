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
# RPROMPT is handled by zsh's own transient_rprompt option, which `on` enables
# and `off` puts back the way it found it.
#
# How it works. Three moving parts, in the order they run:
#
#   precmd            Render the short prompt and cache it, one starship call
#                     per command. Nothing shells out later, so no process spawn
#                     sits between a keypress and the redraw.
#   zle-line-finish   The line is done. Swap PROMPT to the cached string and
#                     reset-prompt, so the line as committed to scrollback keeps
#                     the short prompt.
#   zle -F            Put the full prompt back, deferred. sysopen on /dev/null
#                     gives a descriptor that is always readable, so the handler
#                     fires the moment zle is next active: after the line is
#                     committed, before the next one is edited.
#
# The deferral is why the swap is safe. zle-line-finish also fires for lines that
# were abandoned rather than run, so the prompt sometimes shortens when it should
# not have. Instead of enumerating those cases, the restore is armed at the same
# moment the prompt shortens, and always undoes it.
#
# Ctrl-C never reaches the send-break widget, it arrives as SIGINT, so both paths
# are covered: a TRAPINT for the signal and a send-break wrapper for the widget.
# Both delegate to whatever was already installed rather than replacing it.

0=${(%):-%N}
zmodload zsh/system || return 1
zmodload zsh/parameter 2>/dev/null || return 1
# add-zle-hook-widget needs zsh/zutil already loaded. It keeps its list of valid
# hook names in a zstyle, and on a first call with the module absent it rejects
# every hook name and registers nothing, silently. zstyle on its own works
# without this; add-zle-hook-widget does not.
zmodload zsh/zutil || return 1
autoload -Uz add-zsh-hook add-zle-hook-widget

typeset -g  _ftl_transient_profile=
typeset -g  _ftl_transient_prompt=
typeset -g  _ftl_transient_full_prompt=
typeset -gi _ftl_transient_fd=0
typeset -gi _ftl_transient_active=0
typeset -gi _ftl_transient_set_rprompt=0

# No `emulate -L zsh` here. It implies LOCAL_OPTIONS, which would roll back the
# transient_rprompt setopt below the moment this function returns.
ftl-transient() {
  case $1 in
    on)
      shift
      _ftl_transient_enable "$@" || return
      # zsh already knows how to drop the right prompt from a finished line.
      # Remember whether it was ours to set, so `off` does not clobber a user
      # who had it on already.
      if [[ -o transient_rprompt ]]; then
        _ftl_transient_set_rprompt=0
      else
        _ftl_transient_set_rprompt=1
        setopt transient_rprompt
      fi
      return 0
      ;;
    off)
      _ftl_transient_disable
      (( _ftl_transient_set_rprompt )) && unsetopt transient_rprompt
      _ftl_transient_set_rprompt=0
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

  # Snapshot the real prompt now, not in precmd. The restore is deferred until
  # zle is next active, which is after precmd runs, so at precmd time PROMPT
  # still holds the short value. Snapshotting there would capture the transient
  # prompt as the full one and it would never come back.
  _ftl_transient_full_prompt=$PROMPT

  # Preserve a TRAPINT someone else installed. Ours has to run to catch Ctrl-C,
  # which arrives as a signal and never reaches the send-break widget.
  if (( $+functions[TRAPINT] )) &&
     [[ ${functions[TRAPINT]} != *_ftl_transient_truncate* ]]; then
    functions[_ftl_transient_orig_trapint]=${functions[TRAPINT]}
  fi

  add-zsh-hook precmd _ftl_transient_precmd
  add-zle-hook-widget zle-line-finish _ftl_transient_truncate
  _ftl_transient_wrap_send_break
  _ftl_transient_active=1
}

_ftl_transient_disable() {
  (( _ftl_transient_active )) || return 0

  add-zsh-hook -d precmd _ftl_transient_precmd
  add-zle-hook-widget -d zle-line-finish _ftl_transient_truncate 2>/dev/null
  _ftl_transient_unwrap_send_break

  if (( $+functions[_ftl_transient_orig_trapint] )); then
    functions[TRAPINT]=${functions[_ftl_transient_orig_trapint]}
    unfunction _ftl_transient_orig_trapint
  elif (( $+functions[TRAPINT] )); then
    unfunction TRAPINT
  fi

  (( _ftl_transient_fd )) && { zle -F $_ftl_transient_fd 2>/dev/null; _ftl_transient_fd=0 }

  [[ -n $_ftl_transient_full_prompt ]] && PROMPT=$_ftl_transient_full_prompt
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

# Ask starship what profiles it has, rather than rendering one and inspecting
# the result. An unknown profile is not a failing exit and its complaint does
# not reliably reach stderr, so `starship prompt --profile bogus` is
# indistinguishable from a working one: both exit 0 and print a short prompt.
# `print-config profiles` dumps the computed [profiles] table, which is
# unambiguous.
_ftl_transient_profile_exists() {
  emulate -L zsh
  local name=$1 line key

  for line in ${(f)"$(starship print-config profiles 2>/dev/null)"}; do
    [[ $line == *=* ]] || continue
    key=${line%%=*}
    key=${key//[[:space:]]/}
    key=${key//[\"\']/}
    [[ $key == $name ]] && return 0
  done
  return 1
}

# add_newline defaults to true and applies to profile output as well, which
# would leave a blank line above every committed command. Strip leading
# newlines rather than making every user set add_newline = false.
_ftl_transient_render() {
  emulate -L zsh
  local out
  out=$(starship prompt --profile $1 \
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

  PROMPT=$_ftl_transient_full_prompt
  zle .reset-prompt
  zle -R
}

# send-break is a real widget, not a hook, so it cannot go through
# add-zle-hook-widget. Never replace it outright: `zle -N send-break mine`
# deletes whatever a plugin already installed, and calling `zle .send-break`
# afterwards skips their wrapper for good. Alias the existing binding to a
# private name and delegate to that instead.
_ftl_transient_wrap_send_break() {
  case ${widgets[send-break]:-} in
    user:_ftl_transient_send_break) ;;
    '')
      zle -N send-break _ftl_transient_send_break
      typeset -g _ftl_transient_break_created=1
      ;;
    *)
      zle -A send-break ._ftl_transient_orig::send-break
      zle -N send-break _ftl_transient_send_break
      typeset -g _ftl_transient_break_wrapped=1
      ;;
  esac
}

_ftl_transient_unwrap_send_break() {
  if (( ${+_ftl_transient_break_wrapped} )); then
    zle -A ._ftl_transient_orig::send-break send-break
    zle -D ._ftl_transient_orig::send-break
    unset _ftl_transient_break_wrapped
  elif (( ${+_ftl_transient_break_created} )); then
    zle -D send-break 2>/dev/null
    unset _ftl_transient_break_created
  fi
}

_ftl_transient_send_break() {
  _ftl_transient_truncate
  if (( ${+widgets[._ftl_transient_orig::send-break]} )); then
    zle ._ftl_transient_orig::send-break -- "$@"
  else
    zle .send-break
  fi
}
