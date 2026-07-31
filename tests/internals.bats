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

# --- TRAPINT -----------------------------------------------------------------

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
