#!/usr/bin/env bats
#
# Main suite, against the real starship binary. Fixture configs in
# tests/fixtures/*.toml keep results independent of cwd, git state and the clock.
#
# What cannot use the real binary lives in argument-forwarding.bats; what needs
# no starship at all lives in internals.bats.
#
# The prompt swap itself, Ctrl-C and job notifications are not covered anywhere.
# They need a pty. `just demo` sets one up. Pin `bindkey -e` first, or zsh picks
# viins when $EDITOR looks like vi and ^G stops being send-break. Worth walking:
#
#   Two ordinary commands, then read the scrollback
#   Enter on an empty line, twice
#   Ctrl-C out of a TAB completion menu, a Ctrl-R search, and ESC x, each with no
#     command after it. These are the ones that matter: the editor finished but
#     nothing ran, so the prompt shortens when it should not have and only the
#     deferred restore puts it back
#   Ctrl-C on a typed line, and during a running command, for $? = 130
#   A multi-line command, for the PROMPT2 continuation rows
#   A background job, so its completion notice has to land somewhere
#   `ftl-transient off`, a command, then `on` again
#   The first command of a session with ftl-prompt loaded, where the transient
#     redraw lands between the cursor position ftl-prompt saved and the erase
#     anchored to it

setup() {
  if ! command -v starship >/dev/null 2>&1; then
    skip "starship is not installed"
  fi
  REPO="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  LIB="${REPO}/ftl-transient.zsh"
  FIX="${BATS_TEST_DIRNAME}/fixtures"
}

# Run a zsh snippet with the library sourced and a fixture config active.
zfix() {
  local cfg="$1"; shift
  STARSHIP_CONFIG="${FIX}/${cfg}" zsh -fc "source ${LIB} || exit 1
$1"
}

# Same, interactive, for paths gated behind `[[ -o interactive ]]`.
zfix_i() {
  local cfg="$1"; shift
  STARSHIP_CONFIG="${FIX}/${cfg}" zsh -fic "source ${LIB} || exit 1
$1" 2>/dev/null
}

zfix_i_err() {
  local cfg="$1"; shift
  STARSHIP_CONFIG="${FIX}/${cfg}" zsh -fic "source ${LIB} || exit 1
$1" 2>&1 >/dev/null
}

# --- starship behavior this depends on ---------------------------------------

@test "starship prompt still supports --profile" {
  # Renaming or dropping this flag breaks the approach entirely.
  run starship prompt --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--profile"* ]]
}

@test "starship print-config can report the profiles table" {
  run env STARSHIP_CONFIG="${FIX}/minimal.toml" starship print-config profiles
  [ "$status" -eq 0 ]
  [[ "$output" == *"transient"* ]]
}

@test "an unknown profile exits 0 and prints a prompt anyway" {
  # This is why profile detection uses print-config rather than rendering. A
  # bogus profile is indistinguishable from a good one by exit status, and its
  # complaint does not reliably reach stderr even on a tty.
  run env STARSHIP_CONFIG="${FIX}/minimal.toml" starship prompt --profile bogus
  [ "$status" -eq 0 ]
}

# --- profile detection -------------------------------------------------------

@test "an existing profile is detected" {
  run zfix minimal.toml '_ftl_transient_profile_exists transient && print yes || print no'
  [ "$output" = "yes" ]
}

@test "a second profile in the same table is detected" {
  run zfix minimal.toml '_ftl_transient_profile_exists rtransient && print yes || print no'
  [ "$output" = "yes" ]
}

@test "a missing profile is not detected" {
  run zfix minimal.toml '_ftl_transient_profile_exists nosuchprofile && print yes || print no'
  [ "$output" = "no" ]
}

@test "no profiles table at all means nothing is detected" {
  run zfix no-profiles.toml '_ftl_transient_profile_exists transient && print yes || print no'
  [ "$output" = "no" ]
}

@test "a profile name that is a prefix of another is not a false positive" {
  run zfix minimal.toml '_ftl_transient_profile_exists trans && print yes || print no'
  [ "$output" = "no" ]
}

# --- rendering ---------------------------------------------------------------

@test "render produces the profile's output" {
  # printf brackets because the fixture value ends in a space, which separates
  # the marker from what the user types.
  run zfix minimal.toml 'printf "[%s]" "$(_ftl_transient_render transient)"'
  [ "$output" = "[T> ]" ]
}

@test "render strips the newline add_newline prepends" {
  # Without the strip every committed command gets a blank row above it.
  run zfix add-newline.toml 'out=$(_ftl_transient_render transient)
[[ $out == $'"'"'\n'"'"'* ]] && print LEADING_NEWLINE || print CLEAN'
  [ "$output" = "CLEAN" ]
}

@test "render output is a single row even when the full prompt is not" {
  run zfix multiline.toml 'printf "%s" "$(_ftl_transient_render transient)" | wc -l | tr -d " "'
  [ "$output" = "0" ]
}

@test "the full prompt in that same config spans rows" {
  # Without this, the test above would pass on a one-row fixture.
  run bash -c "STARSHIP_CONFIG='${FIX}/multiline.toml' starship prompt | wc -l | tr -d ' '"
  [ "$output" -gt 1 ]
}

@test "starship doubles a literal percent so PROMPT stays safe" {
  # The transient string is assigned straight to PROMPT, where % is an escape.
  mkdir -p "${BATS_TEST_TMPDIR}/has%percent"
  run bash -c "cd '${BATS_TEST_TMPDIR}/has%percent' && STARSHIP_CONFIG='${FIX}/percent.toml' starship prompt --profile transient"
  [[ "$output" == *"%%percent"* ]]
}

# --- precmd ------------------------------------------------------------------

@test "precmd caches the transient prompt so the widget never shells out" {
  run zfix minimal.toml '_ftl_transient_profile=transient
_ftl_transient_precmd
printf "[%s]" "$_ftl_transient_prompt"'
  [ "$output" = "[T> ]" ]
}

@test "the RPROMPT variable is never modified" {
  # The right prompt is dropped from a finished line by blanking RPROMPT for the
  # one reset-prompt call, so the variable itself is left as the user set it.
  run zfix_i minimal.toml 'RPROMPT="KEEPME"
ftl-transient on transient
printf "[%s]" "$RPROMPT"'
  [[ "$output" == *"[KEEPME]"* ]]
}

@test "the transient_rprompt option is left exactly as it was found" {
  # The widget already drops the right prompt, so there is no reason to flip a
  # global option the user may have set on purpose.
  run zfix_i minimal.toml 'print "before=$options[transientrprompt]"
ftl-transient on transient
print "during=$options[transientrprompt]"
ftl-transient off
print "after=$options[transientrprompt]"'
  [[ "$output" == *"before=off"* ]]
  [[ "$output" == *"during=off"* ]]
  [[ "$output" == *"after=off"* ]]
}

@test "a transient_rprompt the user set is still on afterwards" {
  run zfix_i minimal.toml 'setopt transient_rprompt
ftl-transient on transient
ftl-transient off
print "opt=$options[transientrprompt]"'
  [[ "$output" == *"opt=on"* ]]
}

# --- enable and disable ------------------------------------------------------

@test "enabling accepts a valid profile" {
  run zfix_i minimal.toml 'ftl-transient on transient; print "p=$_ftl_transient_profile"'
  [[ "$output" == *"p=transient"* ]]
}

@test "enabling falls back when the profile does not exist" {
  run zfix_i no-profiles.toml 'ftl-transient on transient
printf "[%s][%s]" "$_ftl_transient_profile" "$_ftl_transient_prompt"'
  [[ "$output" == *"[][]"* ]] || [[ "$output" == *"[]["* ]]
}

@test "enabling with a missing profile explains itself on stderr" {
  run zfix_i_err no-profiles.toml 'ftl-transient on transient'
  [[ "$output" == *"no starship profile 'transient'"* ]]
  [[ "$output" == *"[profiles]"* ]]
}

@test "the default profile name is transient" {
  run zfix_i minimal.toml 'ftl-transient on; print "p=$_ftl_transient_profile"'
  [[ "$output" == *"p=transient"* ]]
}

@test "enabling registers the precmd hook and both line widgets" {
  run zfix_i minimal.toml 'ftl-transient on transient
print "precmd=${#${(@M)precmd_functions:#_ftl_transient_precmd}}"
print "finish=${widgets[zle-line-finish]:+yes}"
print "init=${widgets[zle-line-init]:+yes}"
print "active=$_ftl_transient_active"'
  [ "${lines[0]}" = "precmd=1" ]
  [ "${lines[1]}" = "finish=yes" ]
  [ "${lines[2]}" = "init=yes" ]
  [ "${lines[3]}" = "active=1" ]
}

@test "enabling twice registers the hook only once" {
  run zfix_i minimal.toml 'ftl-transient on transient
ftl-transient on transient
print "count=${#${(@M)precmd_functions:#_ftl_transient_precmd}}"'
  [ "$output" = "count=1" ]
}

@test "disabling removes the precmd hook" {
  run zfix_i minimal.toml 'ftl-transient on transient
ftl-transient off
print "count=${#${(@M)precmd_functions:#_ftl_transient_precmd}}"
print "active=$_ftl_transient_active"'
  [ "${lines[0]}" = "count=0" ]
  [ "${lines[1]}" = "active=0" ]
}

@test "a prompt set after enabling survives the deferred restore" {
  # Any later prompt change, another theme or a `prompt off`, has to stick.
  # Snapshotting at enable time and reassigning in the restore rolls it back on
  # every command instead.
  run zfix_i minimal.toml 'PROMPT="OLD> "
ftl-transient on transient
PROMPT="NEW> "
_ftl_transient_stale=1
_ftl_transient_restore
printf "[%s]" "$PROMPT"'
  [[ "$output" == *"[NEW> ]"* ]]
}

@test "disabling leaves the prompt as it currently is" {
  run zfix_i minimal.toml 'ftl-transient on transient
PROMPT="CURRENT> "
ftl-transient off
printf "[%s]" "$PROMPT"'
  [[ "$output" == *"[CURRENT> ]"* ]]
}

@test "off closes the descriptor it opened" {
  # `zle -F fd` only removes the handler. Without an explicit close the
  # descriptor stays open for the life of the shell, one per on/off cycle.
  run zfix_i minimal.toml 'before=$(print -l /dev/fd/*(N) | wc -l)
repeat 5 { ftl-transient on transient; _ftl_transient_truncate; ftl-transient off }
after=$(print -l /dev/fd/*(N) | wc -l)
print "leaked=$(( after - before ))"'
  [[ "$output" == *"leaked=0"* ]]
}

@test "disabling when never enabled is harmless" {
  run zfix_i minimal.toml 'ftl-transient off; print "rc=$? active=$_ftl_transient_active"'
  [[ "$output" == *"rc=0"* ]]
  [[ "$output" == *"active=0"* ]]
}

# --- example configs ---------------------------------------------------------

@test "examples/single-line.toml parses without complaint" {
  run bash -c "STARSHIP_CONFIG='${REPO}/examples/single-line.toml' starship prompt 2>&1 >/dev/null"
  [ -z "$output" ]
}

@test "examples/multi-line.toml parses without complaint" {
  run bash -c "STARSHIP_CONFIG='${REPO}/examples/multi-line.toml' starship prompt 2>&1 >/dev/null"
  [ -z "$output" ]
}

@test "examples/single-line.toml defines the transient profile" {
  run env STARSHIP_CONFIG="${REPO}/examples/single-line.toml" \
    zsh -fc "source ${LIB}; _ftl_transient_profile_exists transient && print yes || print no"
  [ "$output" = "yes" ]
}

@test "examples/multi-line.toml defines the transient profile" {
  run env STARSHIP_CONFIG="${REPO}/examples/multi-line.toml" \
    zsh -fc "source ${LIB}; _ftl_transient_profile_exists transient && print yes || print no"
  [ "$output" = "yes" ]
}

@test "examples/multi-line.toml collapses from several rows to one" {
  local full transient
  full=$(STARSHIP_CONFIG="${REPO}/examples/multi-line.toml" starship prompt 2>/dev/null | wc -l | tr -d ' ')
  transient=$(STARSHIP_CONFIG="${REPO}/examples/multi-line.toml" \
    zsh -fc "source ${LIB}; printf '%s' \"\$(_ftl_transient_render transient)\"" | wc -l | tr -d ' ')
  [ "$full" -gt 1 ]
  [ "$transient" -eq 0 ]
}

@test "examples/single-line.toml renders a single row" {
  local transient
  transient=$(STARSHIP_CONFIG="${REPO}/examples/single-line.toml" \
    zsh -fc "source ${LIB}; printf '%s' \"\$(_ftl_transient_render transient)\"" | wc -l | tr -d ' ')
  [ "$transient" -eq 0 ]
}
