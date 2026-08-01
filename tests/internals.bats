#!/usr/bin/env bats
#
# Tests for the parts that never touch starship: widget wrapping, trap chaining,
# and the fallback prompt. No starship binary needed, real or fake, so these run
# anywhere and stay fast.

setup() {
  REPO="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  LIB="${REPO}/ftl-transient.zsh"
}

zrun() {
  zsh -fc "source ${LIB} || exit 1
$1"
}

# --- sourcing ----------------------------------------------------------------

@test "sourcing non-interactively still defines the functions" {
  # The interactive check guards activation only. If it moves above the
  # definitions, nothing in this file is reachable.
  run zrun 'print "${+functions[ftl-transient]}${+functions[_ftl_transient_render]}${+functions[_ftl_transient_precmd]}"'
  [ "$status" -eq 0 ]
  [ "$output" = "111" ]
}

@test "enabling in a non-interactive shell is a silent no-op" {
  run zrun 'ftl-transient on; print "active=$_ftl_transient_active"'
  [ "$status" -eq 0 ]
  [ "$output" = "active=0" ]
}

# --- the on/off interface ----------------------------------------------------

@test "no subcommand prints usage and fails" {
  run zsh -fc "source ${LIB} 2>/dev/null; ftl-transient 2>&1 >/dev/null; print \"rc=\$?\""
  [[ "$output" == *"usage: ftl-transient on"* ]]
  [[ "$output" == *"ftl-transient off"* ]]
}

@test "an unknown subcommand prints usage and fails" {
  run zsh -fc "source ${LIB}; ftl-transient enable 2>/dev/null; print \"rc=\$?\""
  [ "$output" = "rc=1" ]
}

@test "off is harmless when never enabled" {
  run zrun 'ftl-transient off; print "rc=$? active=$_ftl_transient_active"'
  [ "$output" = "rc=0 active=0" ]
}

# --- fallback prompt ---------------------------------------------------------

@test "precmd falls back to a plain prompt when no profile is set" {
  run zrun '_ftl_transient_precmd; printf "[%s]" "$_ftl_transient_prompt"'
  [ "$status" -eq 0 ]
  [ "$output" = "[%# ]" ]
}

# --- the prompt swap ---------------------------------------------------------

@test "the truncation touches the left prompt only" {
  # Whether a finished line keeps its right prompt is the user's call, made with
  # zsh's own transient_rprompt.
  run zrun 'print -r -- ${functions[_ftl_transient_truncate]}'
  [[ "$output" == *'PROMPT=$_ftl_transient_prompt'* ]]
  [[ "$output" != *'RPROMPT'* ]]
}

@test "a command-prefix assignment does not outlive the command" {
  # truncate swaps with `PROMPT=$short zle .reset-prompt`, scoped to that one
  # command, so PROMPT is full again the moment it returns. Nothing downstream may
  # assume it was left short.
  run zrun 'PROMPT=FULL; () { PROMPT=SHORT builtin true }; printf "[%s]" "$PROMPT"'
  [ "$output" = "[FULL]" ]
}

@test "the deferred restore stands down once a fresh prompt has been drawn" {
  # line-init has already drawn the real prompt by then, so a redraw would be a
  # second full render of a prompt that is already correct.
  run zrun '_ftl_transient_stale=1
_ftl_transient_fresh
print "stale=$_ftl_transient_stale"'
  [ "$output" = "stale=0" ]
}

@test "the restore releases its descriptor even when it skips the redraw" {
  # Arming happens ahead of the `zle` guard, so a truncate outside the editor
  # still opens the descriptor. Bailing out early must not strand it.
  run zrun '_ftl_transient_truncate
_ftl_transient_stale=0
_ftl_transient_restore $_ftl_transient_fd
print "rc=$? fd=$_ftl_transient_fd"'
  [ "$output" = "rc=0 fd=0" ]
}

# --- TRAPINT -----------------------------------------------------------------

@test "a TRAPINT installed after enabling is still preserved" {
  # The chain is rebuilt every precmd, not once at enable time. A trap installed
  # later would otherwise be overwritten on the next prompt and never run again.
  run zrun '_ftl_transient_precmd
TRAPINT() { print "foreign ran"; return 99 }
_ftl_transient_precmd
TRAPINT 2
print "rc=$?"'
  [ "${lines[0]}" = "foreign ran" ]
  [ "${lines[1]}" = "rc=99" ]
}

@test "off leaves a foreign TRAPINT alone when ours was never installed" {
  # The chain is built in precmd, not enable, so `off` before the first precmd has
  # nothing of ours to take out. Removing TRAPINT there would take someone else's.
  run zsh -fc "source ${LIB} || exit 1
zmodload zsh/zle 2>/dev/null
TRAPINT() { print 'foreign ran'; return 99 }
_ftl_transient_active=1
_ftl_transient_disable
print \"trapint=\${+functions[TRAPINT]}\"" 2>/dev/null
  [[ "$output" == *"trapint=1"* ]]
}

@test "off removes the TRAPINT it installed itself" {
  run zsh -fc "source ${LIB} || exit 1
zmodload zsh/zle 2>/dev/null
_ftl_transient_precmd
_ftl_transient_active=1
_ftl_transient_disable
print \"trapint=\${+functions[TRAPINT]}\"" 2>/dev/null
  [[ "$output" == *"trapint=0"* ]]
}

@test "rebuilding the chain every precmd does not nest us inside ourselves" {
  # Ours must never be captured as the "original", or each cycle wraps the last
  # and the recursion grows without bound.
  run zrun 'repeat 3 { _ftl_transient_precmd }
print "orig=${+functions[_ftl_transient_orig_trapint]}"'
  [ "$output" = "orig=0" ]
}

@test "TRAPINT survives precmd returning" {
  # `emulate -L zsh` at the top of the precmd hook implies LOCAL_TRAPS, which
  # drops the TRAPINT it installs as soon as precmd returns. Ctrl-C then stops
  # shortening the prompt, with no error anywhere.
  run zrun '_ftl_transient_precmd; print "${+functions[TRAPINT]}"'
  [ "$output" = "1" ]
}

@test "TRAPINT reports 128 plus the signal number" {
  run zrun '_ftl_transient_precmd; TRAPINT 2; print "rc=$?"'
  [ "$output" = "rc=130" ]
}

@test "TRAPINT delegates to a trap that was already installed" {
  run zrun 'TRAPINT() { print "foreign ran"; return 99 }
functions[_ftl_transient_orig_trapint]=${functions[TRAPINT]}
_ftl_transient_precmd
TRAPINT 2
print "rc=$?"'
  [ "${lines[0]}" = "foreign ran" ]
  [ "${lines[1]}" = "rc=99" ]
}

# --- surviving another plugin owning zle-line-finish -------------------------

@test "the repair takes over a zle-line-finish another plugin rebound" {
  # Registered in the chain but unreachable once the widget is replaced outright.
  run zrun 'zmodload zsh/zle
foreign() { : }
zle -N zle-line-finish foreign
_ftl_transient_repair_line_finish
print "now=${widgets[zle-line-finish]}"
print "saved=${widgets[._ftl_transient_orig::zle-line-finish]:-NONE}"'
  [ "${lines[0]}" = "now=user:_ftl_transient_line_finish" ]
  [ "${lines[1]}" = "saved=user:foreign" ]
}

@test "the repair handles a bare function named after the hook" {
  # The shape the breakage takes in the wild. Widget and function share a name, so
  # the saved alias must resolve to the function, not back to our wrapper.
  run zrun 'zmodload zsh/zle
function zle-line-finish() { : }
zle -N zle-line-finish
print "hostile=${widgets[zle-line-finish]}"
_ftl_transient_repair_line_finish
print "now=${widgets[zle-line-finish]}"
print "saved=${widgets[._ftl_transient_orig::zle-line-finish]:-NONE}"'
  [ "${lines[0]}" = "hostile=user:zle-line-finish" ]
  [ "${lines[1]}" = "now=user:_ftl_transient_line_finish" ]
  [ "${lines[2]}" = "saved=user:zle-line-finish" ]
}

@test "off restores a bare function named after the hook" {
  run zrun 'zmodload zsh/zle
function zle-line-finish() { : }
zle -N zle-line-finish
_ftl_transient_repair_line_finish
_ftl_transient_active=1
_ftl_transient_disable
print "now=${widgets[zle-line-finish]}"'
  [ "$output" = "now=user:zle-line-finish" ]
}

@test "the repair leaves the sanctioned chain alone" {
  run zrun 'zmodload zsh/zle
add-zle-hook-widget zle-line-finish _ftl_transient_truncate
_ftl_transient_repair_line_finish
print "now=${widgets[zle-line-finish]}"'
  [ "$output" = "now=user:azhw:zle-line-finish" ]
}

@test "repairing twice does not nest us inside ourselves" {
  run zrun 'zmodload zsh/zle
foreign() { : }
zle -N zle-line-finish foreign
_ftl_transient_repair_line_finish
_ftl_transient_repair_line_finish
print "saved=${widgets[._ftl_transient_orig::zle-line-finish]}"'
  [ "$output" = "saved=user:foreign" ]
}

@test "the repair installs the hook when nothing has bound it" {
  run zrun 'zmodload zsh/zle
_ftl_transient_repair_line_finish
print "now=${widgets[zle-line-finish]:-NONE}"'
  [ "$output" = "now=user:azhw:zle-line-finish" ]
}

@test "off hands back a zle-line-finish taken from another plugin" {
  run zrun 'zmodload zsh/zle
foreign() { : }
zle -N zle-line-finish foreign
_ftl_transient_repair_line_finish
_ftl_transient_active=1
_ftl_transient_disable
print "now=${widgets[zle-line-finish]}"
print "leftover=${widgets[._ftl_transient_orig::zle-line-finish]:-NONE}"'
  [ "${lines[0]}" = "now=user:foreign" ]
  [ "${lines[1]}" = "leftover=NONE" ]
}

@test "precmd runs the repair, so a later rebind is undone next prompt" {
  run zrun 'zmodload zsh/zle
add-zle-hook-widget zle-line-finish _ftl_transient_truncate
foreign() { : }
zle -N zle-line-finish foreign
_ftl_transient_precmd
print "now=${widgets[zle-line-finish]}"'
  [ "$output" = "now=user:_ftl_transient_line_finish" ]
}

# --- send-break wrapping -----------------------------------------------------

@test "wrapping send-break preserves a binding another plugin installed" {
  run zrun 'zmodload zsh/zle
foreign_break() { : }
zle -N send-break foreign_break
_ftl_transient_wrap_send_break
print "now=${widgets[send-break]}"
print "saved=${widgets[._ftl_transient_orig::send-break]:-NONE}"'
  [ "${lines[0]}" = "now=user:_ftl_transient_send_break" ]
  [ "${lines[1]}" = "saved=user:foreign_break" ]
}

@test "unwrapping restores the original send-break binding" {
  run zrun 'zmodload zsh/zle
foreign_break() { : }
zle -N send-break foreign_break
_ftl_transient_wrap_send_break
_ftl_transient_unwrap_send_break
print "restored=${widgets[send-break]}"
print "leftover=${widgets[._ftl_transient_orig::send-break]:-NONE}"'
  [ "${lines[0]}" = "restored=user:foreign_break" ]
  [ "${lines[1]}" = "leftover=NONE" ]
}

@test "unwrapping restores the builtin when no plugin had bound send-break" {
  # send-break always exists, so an untouched one reads as "builtin" rather than
  # empty. Unwrapping hands that back instead of deleting the widget.
  run zrun 'zmodload zsh/zle
print "before=${widgets[send-break]}"
_ftl_transient_wrap_send_break
print "wrapped=${widgets[send-break]}"
_ftl_transient_unwrap_send_break
print "after=${widgets[send-break]}"'
  [ "${lines[0]}" = "before=builtin" ]
  [ "${lines[1]}" = "wrapped=user:_ftl_transient_send_break" ]
  [ "${lines[2]}" = "after=builtin" ]
}

@test "wrapping twice does not nest us inside ourselves" {
  run zrun 'zmodload zsh/zle
foreign_break() { : }
zle -N send-break foreign_break
_ftl_transient_wrap_send_break
_ftl_transient_wrap_send_break
print "saved=${widgets[._ftl_transient_orig::send-break]}"'
  [ "$output" = "saved=user:foreign_break" ]
}
