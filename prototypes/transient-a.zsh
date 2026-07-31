#!/usr/bin/env zsh
#
# transient-a.zsh -- technique 1: truncate in zle-line-finish, restore deferred
#
# This is the technique powerlevel10k uses, in the form romkatv described but
# never published: do not try to stop the wrong truncation from happening, just
# undo it quickly once it is clear it should not have happened.
#
# The deferral is the whole trick. sysopen on /dev/null gives a descriptor that
# is always readable, so `zle -F fd handler` fires the moment zle is next
# active. That is after the line is committed and before the next line is
# edited, which is exactly when the full prompt should come back.
#
# Known cosmetic artifact: ESC x (execute-named-cmd) followed by Ctrl-C leaves
# a bare short prompt line in scrollback. The line editor finished, so the
# truncation is technically correct, but nothing was run. Measured on zsh
# 5.9.2. It does not wedge the prompt and the next command is clean.
#
# Usage:
#   source transient-a.zsh && ftl-transient-a-on
#   ftl-transient-a-off

0=${(%):-%N}
source ${0:A:h}/transient-common.zsh || return 1
zmodload zsh/system || return 1

typeset -gi _ftl_tp_fd=0

_ftl_tp_a_truncate() {
  # Arm the deferred restore before redrawing, once per cycle.
  (( ! _ftl_tp_fd )) && {
    sysopen -r -o cloexec -u _ftl_tp_fd /dev/null
    zle -F $_ftl_tp_fd _ftl_tp_a_restore
  }

  # Guard on `zle`: TRAPINT can reach here with the editor already gone.
  zle || return 0
  PROMPT=$_ftl_tp_transient RPROMPT=$_ftl_tp_transient_r zle .reset-prompt
  zle -R
}

# Called by `zle -F` with the fd as $1.
_ftl_tp_a_restore() {
  exec {1}>&-
  (( ${+1} )) && zle -F $1
  _ftl_tp_fd=0

  PROMPT=$_ftl_tp_full_prompt
  RPROMPT=$_ftl_tp_full_rprompt
  zle .reset-prompt
  zle -R
}

# Ctrl-C during editing does not run zle-line-finish, so the prompt would stay
# long on the abandoned line. TRAPINT covers the signal path, the send-break
# wrapper covers the widget path.
_ftl_tp_a_precmd_trap() {
  TRAPINT() {
    zle && _ftl_tp_a_truncate
    return $(( 128 + $1 ))
  }
}

_ftl_tp_a_send_break() {
  _ftl_tp_a_truncate
}

ftl-transient-a-on() {
  _ftl_tp_setup || return 1

  # zle-line-finish is a hook, so use the sanctioned chaining mechanism. It
  # composes with other plugins' hooks and has a documented removal path.
  add-zle-hook-widget zle-line-finish _ftl_tp_a_truncate

  # send-break is a real widget, not a hook, so it needs backup-and-delegate.
  # Ours first so the prompt is already short when the break is delivered.
  _ftl_tp_wrap_widget send-break _ftl_tp_a_send_break before

  add-zsh-hook precmd _ftl_tp_a_precmd_trap
  print -r -- "ftl-transient: technique A active (zle-line-finish + deferred restore)"
}

ftl-transient-a-off() {
  add-zle-hook-widget -d zle-line-finish _ftl_tp_a_truncate 2>/dev/null
  add-zsh-hook -d precmd _ftl_tp_a_precmd_trap
  unset -f TRAPINT 2>/dev/null
  (( _ftl_tp_fd )) && { zle -F $_ftl_tp_fd 2>/dev/null; _ftl_tp_fd=0 }
  _ftl_tp_teardown
  print -r -- "ftl-transient: technique A removed"
}
