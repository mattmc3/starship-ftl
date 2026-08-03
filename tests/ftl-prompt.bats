#!/usr/bin/env bats
#
# Tests for ftl-prompt.zsh.
#
# bats runs with stdout on a pipe, so `[[ -t 1 ]]` is false and ftl-prompt takes
# its non-drawing branch every time. That covers argument handling, fpath setup,
# theme discovery and the fallback path, and it cannot cover the drawing itself.
# The scroll, save, draw, erase and replay need a real terminal: drawing.bats
# gets one from zsh/zpty, and the rest is checked by hand against examples/*.toml.
#
# Every helper clears FPATH and STARSHIP_CONFIG and pins ZDOTDIR and
# XDG_CONFIG_HOME. Both leak: an exported STARSHIP_CONFIG decides which config is
# read, and an exported FPATH can put another prompt_starship_setup ahead of this
# repo's, so the suite ends up testing whatever theme the machine already had.

setup() {
  if ! command -v starship >/dev/null 2>&1; then
    skip "starship is not installed"
  fi
  REPO="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  LIB="${REPO}/ftl-prompt.zsh"
  FIX="${BATS_TEST_DIRNAME}/fixtures"
}

# Clean env, library sourced, snippet run.
zclean() {
  env -u STARSHIP_CONFIG -u ZDOTDIR -u FPATH \
      PATH="$PATH" HOME="$HOME" \
      XDG_CONFIG_HOME="${BATS_TEST_TMPDIR}/xdg" \
      XDG_CACHE_HOME="${BATS_TEST_TMPDIR}/cache" \
      zsh -fc "source ${LIB} || exit 1
$1"
}

# With a fixture config, for cases that render a prompt.
zconf() {
  env -u ZDOTDIR -u FPATH PATH="$PATH" HOME="$HOME" \
      STARSHIP_CONFIG="${FIX}/plain.toml" \
      XDG_CACHE_HOME="${BATS_TEST_TMPDIR}/cache" \
      zsh -fc "source ${LIB} || exit 1
$1"
}

# --- fpath and loading -------------------------------------------------------

@test "sourcing puts the themes directory on fpath" {
  run zclean 'print "${#${(@M)fpath:#*/themes}}"'
  [ "$output" -ge 1 ]
}

@test "sourcing twice does not duplicate the fpath entry" {
  run zclean 'source '"${REPO}"'/ftl-prompt.zsh
print "count=${#${(@M)fpath:#'"${REPO}"'/themes}}"'
  [ "$output" = "count=1" ]
}

@test "fpath is a unique array" {
  # typeset -gUa, so a duplicate added by anything else collapses too.
  run zclean 'fpath+=(/tmp) ; fpath+=(/tmp); print "count=${#${(@M)fpath:#/tmp}}"'
  [ "$output" = "count=1" ]
}

@test "the version is exposed" {
  run zclean 'print "${STARSHIP_FTL_VERSION:-unset}"'
  [ "$output" != "unset" ]
}

@test "promptinit can find the starship theme" {
  run zclean 'autoload -Uz promptinit; promptinit; print "${prompt_themes[(r)starship]:-NO}"'
  [ "$output" = "starship" ]
}

@test "the plugin entry point loads the same way" {
  run env -u STARSHIP_CONFIG -u FPATH PATH="$PATH" HOME="$HOME" \
    zsh -fc "source ${REPO}/starship-ftl.plugin.zsh
print \"fn=\${+functions[ftl-prompt]} themes=\${#\${(@M)fpath:#${REPO}/themes}}\""
  [ "$output" = "fn=1 themes=1" ]
}

@test "the theme resolved is this repo's, not one already on the machine" {
  # Without clearing FPATH the rest of the suite would test whichever copy the
  # developer already had installed.
  run zclean 'for d in $fpath; do
  [[ -f $d/prompt_starship_setup ]] && print "$d"
done'
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == "${REPO}/themes" ]]
}

@test "the themes directory is prepended, not appended" {
  run zclean 'print "$fpath[1]"'
  [ "$output" = "${REPO}/themes" ]
}

@test "a competing theme earlier on fpath does not win" {
  # An abandoned prompt_starship_setup in a user's dotfiles must not shadow
  # this one, which it would do silently.
  run zclean 'mkdir -p ${XDG_CONFIG_HOME}/other
: > ${XDG_CONFIG_HOME}/other/prompt_starship_setup
fpath=(${XDG_CONFIG_HOME}/other $fpath)
source '"${REPO}"'/ftl-prompt.zsh
print "$fpath[1]"'
  [ "$output" = "${REPO}/themes" ]
}

@test "re-sourcing keeps the themes directory first without duplicating it" {
  run zclean 'fpath=(/tmp $fpath)
source '"${REPO}"'/ftl-prompt.zsh
print "first=$fpath[1] count=${#${(@M)fpath:#'"${REPO}"'/themes}}"'
  [ "$output" = "first=${REPO}/themes count=1" ]
}

# --- argument handling -------------------------------------------------------

@test "no theme argument is an error" {
  run zclean 'ftl-prompt; print "rc=$?"'
  [ "$output" = "rc=1" ]
}

@test "an unknown flag is an error" {
  run zclean 'ftl-prompt -x foo; print "rc=$?"'
  [ "$output" = "rc=1" ]
}

@test "-p without a theme after it is an error" {
  run zclean 'ftl-prompt -p "approx> "; print "rc=$?"'
  [ "$output" = "rc=1" ]
}

@test "-- ends option parsing" {
  run zconf 'ftl-prompt -- starship >/dev/null 2>&1; print "rc=$?"'
  [ "$output" = "rc=0" ]
}

@test "a theme name that looks like a flag is rejected rather than treated as one" {
  run zclean 'ftl-prompt --nope; print "rc=$?"'
  [ "$output" = "rc=1" ]
}

# --- the non-drawing fallback ------------------------------------------------

@test "without a terminal the theme is set the ordinary way" {
  run zconf 'ftl-prompt starship >/dev/null 2>&1
print "rc=$? ps1=${PS1:+set}"'
  [ "$output" = "rc=0 ps1=set" ]
}

@test "the fallback installs no precmd hook" {
  # Nothing was drawn, so there is nothing to erase. A hook here would erase a
  # region that was never written.
  run zconf 'ftl-prompt starship >/dev/null 2>&1
print "hook=${#${(@M)precmd_functions:#_ftl_prompt_clear}}"'
  [ "$output" = "hook=0" ]
}

@test "the fallback leaves prompt_cr and prompt_sp alone" {
  # Those are only suspended to protect a drawn prompt from PROMPT_EOL_MARK.
  run zconf 'ftl-prompt starship >/dev/null 2>&1
print "cr=${options[promptcr]} sp=${options[promptsp]}"'
  [ "$output" = "cr=on sp=on" ]
}

@test "-p is accepted and ignored when nothing is drawn" {
  run zconf 'ftl-prompt -p "approx> " starship >/dev/null 2>&1
print "rc=$? ps1=${PS1:+set}"'
  [ "$output" = "rc=0 ps1=set" ]
}

# --- the theme's prompt options reach the shell -------------------------------

@test "a theme's requested prompt options are applied" {
  # zsh's `prompt` only applies prompt_opts when called from a scope without
  # LOCAL_OPTIONS, so `emulate -L zsh` in _ftl_prompt_main would swallow them.
  run zconf 'ftl-prompt starship >/dev/null 2>&1
print "subst=${options[promptsubst]} percent=${options[promptpercent]}"'
  [ "$output" = "subst=on percent=on" ]
}

@test "prompt expansion does not leak prompt_subst on its own" {
  # _ftl_prompt_expand scopes it, so with no theme loaded nothing changes.
  run zclean 'print "before=${options[promptsubst]}"
_ftl_prompt_expand "%~" >/dev/null
print "after=${options[promptsubst]}"'
  [ "${lines[0]}" = "before=off" ]
  [ "${lines[1]}" = "after=off" ]
}

@test "prompt expansion expands a command substitution" {
  # This is the shape starship's PS1 takes, and the reason prompt_subst matters.
  run zclean '_ftl_prompt_expand "$(print EXPANDED)"'
  [ "$output" = "EXPANDED" ]
}

# --- output capture ----------------------------------------------------------

@test "capture writes its log under XDG_CACHE_HOME" {
  # The function redirects stdout into the log, so the check has to happen after
  # the descriptors are restored rather than by printing inside it.
  run zconf 'mkdir -p ${XDG_CACHE_HOME}
_ftl_prompt_capture
logpath=$_ftl_prompt_log
exec 1>&$_ftl_prompt_fd1 2>&$_ftl_prompt_fd2
print "under_cache=${logpath:#${XDG_CACHE_HOME}/*}"
print "exists=$([[ -f $logpath ]] && print yes || print no)"'
  [ "${lines[0]}" = "under_cache=" ]
  [ "${lines[1]}" = "exists=yes" ]
}

@test "captured output lands in the log rather than on the terminal" {
  run zconf 'mkdir -p ${XDG_CACHE_HOME}
_ftl_prompt_capture
print "SWALLOWED"
logpath=$_ftl_prompt_log
exec 1>&$_ftl_prompt_fd1 2>&$_ftl_prompt_fd2
print "log_has=$(<$logpath)"'
  [ "$output" = "log_has=SWALLOWED" ]
}

@test "capture survives an unwritable cache directory" {
  # It gives up on capturing rather than failing the prompt.
  run zconf 'XDG_CACHE_HOME=/proc/nonexistent-ftl
_ftl_prompt_capture
print "rc=$? log=${_ftl_prompt_log:-unset}"'
  [[ "$output" == *"rc=0"* ]]
  [[ "$output" == *"log=unset"* ]]
}

# --- what counts as output worth a row ---------------------------------------

@test "an escape sequence on its own is not visible output" {
  # Terminal.app's shell integration writes one of these from its own precmd.
  run zclean "_ftl_prompt_visible \$'\\e]7;file:///tmp\\a'; print \"rc=\$?\""
  [ "$output" = "rc=1" ]
}

@test "colouring around real text is still visible output" {
  run zclean "_ftl_prompt_visible \$'\\e[1mdirenv: loading\\e[0m'; print \"rc=\$?\""
  [ "$output" = "rc=0" ]
}

@test "nothing captured is not visible output" {
  run zclean '_ftl_prompt_visible ""; print "rc=$?"'
  [ "$output" = "rc=1" ]
}

# --- reporting failure -------------------------------------------------------

@test "a theme that cannot load is reported as a failure" {
  # zsh's own `prompt` returns 0 even when a theme's setup function fails, so
  # this has to be detected rather than passed through. Without it,
  # `ftl-prompt starship || handle_it` never fires.
  run env -i PATH=/usr/bin:/bin HOME="$HOME" \
    zsh -fc "source ${LIB}; ftl-prompt starship 2>/dev/null; print \"rc=\$?\""
  [ "$output" = "rc=1" ]
}

@test "a theme that cannot load says why on stderr" {
  run env -i PATH=/usr/bin:/bin HOME="$HOME" \
    zsh -fc "source ${LIB}; ftl-prompt starship 2>&1 >/dev/null"
  [[ "$output" == *"starship command not found"* ]]
}

@test "an unknown theme name is a failure" {
  run zclean 'ftl-prompt nosuchtheme >/dev/null 2>&1; print "rc=$?"'
  [ "$output" = "rc=1" ]
}

@test "a theme that loads is reported as success" {
  run zconf 'ftl-prompt starship >/dev/null 2>&1; print "rc=$?"'
  [ "$output" = "rc=0" ]
}

@test "a failed load leaves the previous prompt in place" {
  # Nothing was drawn in this branch, so bailing out is safe and the shell keeps
  # whatever prompt it already had.
  run env -i PATH=/usr/bin:/bin HOME="$HOME" \
    zsh -fc "source ${LIB}
PS1='KEEPME> '
ftl-prompt starship 2>/dev/null
printf '[%s]' \"\$PS1\""
  [ "$output" = "[KEEPME> ]" ]
}

@test "a stale prompt_theme does not make a failure look like success" {
  # `prompt` only records prompt_theme on success, so it is cleared first.
  # Otherwise a previously loaded theme reads as this one having worked.
  run env -i PATH=/usr/bin:/bin HOME="$HOME" \
    zsh -fc "source ${LIB}
prompt_theme=(starship)
ftl-prompt starship 2>/dev/null
print \"rc=\$?\""
  [ "$output" = "rc=1" ]
}
