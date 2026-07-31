#!/usr/bin/env zsh
#
# transient-common.zsh
#
# Shared plumbing for the two transient prompt prototypes. Both need the same
# two things, and both need them to behave identically, or an A/B comparison
# measures the plumbing instead of the technique:
#
#   1. Widget wrapping that does not stomp on bindings we did not create.
#   2. A short prompt string rendered from starship, precomputed off the
#      keypress path.
#
# Nothing here is specific to either technique.

zmodload zsh/parameter 2>/dev/null || return 1
autoload -Uz add-zsh-hook add-zle-hook-widget

typeset -g  _ftl_tp_full_prompt=
typeset -g  _ftl_tp_full_rprompt=
typeset -g  _ftl_tp_transient=
typeset -g  _ftl_tp_transient_r=
typeset -ga _ftl_tp_wrapped=()
typeset -ga _ftl_tp_created=()

# --- widget wrapping ---------------------------------------------------------
#
# The rule: never replace a widget without keeping a way to call what was there.
# A bare `zle -N send-break mine` silently deletes a binding some other plugin
# installed, and calling `zle .send-break` afterwards skips their wrapper for
# good. Both shipping implementations of this feature (powerlevel10k and
# oh-my-posh) back up and delegate instead. This is oh-my-posh's
# `_omp_create_widget` pattern with an explicit call order.
#
# order=before  our function runs, then the original
# order=after   the original runs, then our function, original's status wins

_ftl_tp_wrap_widget() {
  local widget=$1 fn=$2 order=${3:-before}
  local saved="._ftl_tp_orig::$widget"

  case ${widgets[$widget]:-} in
    # Already ours. Re-wrapping would nest us inside ourselves.
    user:_ftl_tp_decorated_*) return 0 ;;

    # Nothing bound. Safe to create outright, and remember that we created it
    # so unload deletes it rather than restoring a binding that never existed.
    '')
      zle -N $widget $fn
      _ftl_tp_created+=($widget)
      return 0
      ;;

    # Someone else owns it, builtin or plugin. Alias the existing binding to a
    # private name and delegate to that name, never to the `.builtin` form.
    *)
      zle -A $widget $saved
      if [[ $order == before ]]; then
        eval "_ftl_tp_decorated_${(q)widget}() {
          ${(q)fn} \"\$@\"
          zle ${(q)saved} -- \"\$@\"
        }"
      else
        eval "_ftl_tp_decorated_${(q)widget}() {
          zle ${(q)saved} -- \"\$@\"
          local -i _ftl_tp_ret=\$?
          ${(q)fn} \"\$@\"
          return \$_ftl_tp_ret
        }"
      fi
      zle -N $widget _ftl_tp_decorated_$widget
      _ftl_tp_wrapped+=($widget)
      return 0
      ;;
  esac
}

_ftl_tp_unwrap_widgets() {
  local widget saved
  for widget in $_ftl_tp_wrapped; do
    saved="._ftl_tp_orig::$widget"
    if (( ${+widgets[$saved]} )); then
      zle -A $saved $widget
      zle -D $saved
    fi
    (( ${+functions[_ftl_tp_decorated_$widget]} )) &&
      unfunction _ftl_tp_decorated_$widget
  done
  for widget in $_ftl_tp_created; do
    (( ${+widgets[$widget]} )) && zle -D $widget
  done
  _ftl_tp_wrapped=()
  _ftl_tp_created=()
}

# --- rendering ---------------------------------------------------------------

# Probe once at install. A missing profile is not an error exit in starship
# 1.26: it prints a diagnostic on stderr, an empty prompt on stdout, and exits
# 0. So detect it by looking at stderr, not $?.
_ftl_tp_profile_ok() {
  local profile=$1 err
  err=$(starship prompt --profile $profile 2>&1 >/dev/null)
  [[ -z $err ]]
}

# `add_newline` (default true) prepends a blank line to profile output too,
# which would leave an empty line above every committed command. Strip leading
# newlines rather than making every user set add_newline = false.
_ftl_tp_render() {
  local profile=$1 out
  out=$(starship prompt --profile $profile \
          --terminal-width="$COLUMNS" \
          --status="${STARSHIP_CMD_STATUS:-0}" \
          --pipestatus="${STARSHIP_PIPE_STATUS[*]:-}" \
          --cmd-duration="${STARSHIP_DURATION:-0}" \
          --jobs="${STARSHIP_JOBS_COUNT:-0}" \
          --keymap="${KEYMAP:-}" 2>/dev/null)
  print -rn -- ${out##$'\n'##}
}

# Snapshot the real prompt at install time, not in precmd. By the time precmd
# runs, PROMPT still holds the transient value: the restore is deferred until
# zle is next active, which is after precmd. Snapshotting there would capture
# the short prompt as the "full" one and the prompt would never come back.
_ftl_tp_snapshot_prompt() {
  _ftl_tp_full_prompt=$PROMPT
  _ftl_tp_full_rprompt=$RPROMPT
}

_ftl_tp_setup() {
  local profile rprofile

  [[ -o interactive ]] || return 1
  (( $+commands[starship] )) || {
    print -ru2 -- "ftl-transient: starship not found"
    return 1
  }

  zstyle -s ':ftl-prompt:' transient-profile profile || profile=transient
  zstyle -s ':ftl-prompt:' transient-rprofile rprofile || rprofile=

  if _ftl_tp_profile_ok $profile; then
    typeset -g _ftl_tp_profile=$profile
  else
    print -ru2 -- "ftl-transient: starship profile '$profile' not found, using '%# '"
    typeset -g _ftl_tp_profile=
  fi
  typeset -g _ftl_tp_rprofile=$rprofile

  _ftl_tp_snapshot_prompt
  add-zsh-hook precmd _ftl_tp_precmd
  return 0
}

# One starship call per command, here rather than in the widget. Rendering
# inside the widget puts a process spawn between the keypress and the redraw,
# which is exactly the latency this project exists to avoid.
_ftl_tp_precmd() {
  if [[ -n $_ftl_tp_profile ]]; then
    _ftl_tp_transient=$(_ftl_tp_render $_ftl_tp_profile)
  else
    _ftl_tp_transient='%# '
  fi
  if [[ -n $_ftl_tp_rprofile ]]; then
    _ftl_tp_transient_r=$(_ftl_tp_render $_ftl_tp_rprofile)
  else
    _ftl_tp_transient_r=
  fi
}

_ftl_tp_teardown() {
  add-zsh-hook -d precmd _ftl_tp_precmd
  _ftl_tp_unwrap_widgets
  [[ -n $_ftl_tp_full_prompt ]] && PROMPT=$_ftl_tp_full_prompt
  RPROMPT=$_ftl_tp_full_rprompt
}
