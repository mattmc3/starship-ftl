#!/usr/bin/env zsh
#
# transient-b.zsh -- technique 2: wrap the editing session in recursive-edit
#
# This is oh-my-posh's technique, and the one starship#4205 proposed. Instead of
# reacting to the line finishing, take over zle-line-init and run the entire
# editing session inside `zle .recursive-edit`. When it returns, the line is
# done, so the prompt can be shortened with certainty. No guessing, no deferred
# recovery, no TRAPINT.
#
# The cost is structural rather than cosmetic. Because the session runs nested,
# the shell cannot report background job completions until the line finishes,
# as though `no_notify` were set. romkatv flagged this in 2019 and it is why he
# considers this approach unusable; the starship PR was blocked over it. It also
# mishandles status on interrupt: `zle .send-break` leaves $? at 1 rather than
# 130. oh-my-posh carries that as a TODO in its own source.
#
# Usage:
#   source transient-b.zsh && ftl-transient-b-on
#   ftl-transient-b-off

0=${(%):-%N}
source ${0:A:h}/transient-common.zsh || return 1

_ftl_tp_b_line_init() {
  # Only take over a fresh top-level line. Anything else (a continuation, a
  # nested editor) must be left alone or we recurse into ourselves.
  [[ $CONTEXT == start ]] || return 0

  local -i ret=0
  while true; do
    zle .recursive-edit
    ret=$?
    # Ctrl-D on an empty buffer arrives as a successful edit with EOT in $KEYS.
    [[ $ret == 0 && $KEYS == $'\4' ]] || break
    [[ -o ignore_eof ]] || exit 0
  done

  PROMPT=$_ftl_tp_transient
  RPROMPT=$_ftl_tp_transient_r
  zle .reset-prompt
  PROMPT=$_ftl_tp_full_prompt
  RPROMPT=$_ftl_tp_full_rprompt

  if (( ret )); then
    # Known wrong: this sets $? to 1, not 130 as a real SIGINT would.
    zle .send-break
  else
    zle .accept-line
  fi
  return ret
}

ftl-transient-b-on() {
  _ftl_tp_setup || return 1

  # Caveat specific to this technique: our hook consumes the whole editing
  # session, so any zle-line-init hook registered after ours does not run until
  # the line is already finished. oh-my-posh hit this with zsh-vi-mode and had
  # to special-case it. Enable this before other prompt plugins, not after.
  add-zle-hook-widget zle-line-init _ftl_tp_b_line_init

  print -r -- "ftl-transient: technique B active (zle-line-init + recursive-edit)"
  print -r -- "ftl-transient: expect suppressed job notifications and \$? == 1 on Ctrl-C"
}

ftl-transient-b-off() {
  add-zle-hook-widget -d zle-line-init _ftl_tp_b_line_init 2>/dev/null
  _ftl_tp_teardown
  print -r -- "ftl-transient: technique B removed"
}
