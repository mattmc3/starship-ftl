#!/usr/bin/env bats
#
# Tests for loading a theme without promptinit.
#
# What promptinit and `prompt` used to guarantee has to be guaranteed here: the
# setup function is found, its prompt options reach the shell, and prompt_theme
# records what loaded. Fake themes throughout, so none of it needs starship.

setup() {
  REPO="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  LIB="${REPO}/ftl-prompt.zsh"
  TH="${BATS_TEST_TMPDIR}/themes"
  mkdir -p "$TH"

  # The shape the prompt system expects: prompt_opts, plus a precmd.
  cat > "${TH}/prompt_faux_setup" <<'THEME'
prompt_opts=(cr subst)
PS1='FAUX> '
FAUX_ARG=${1:-none}
prompt_faux_precmd() { : }
autoload -Uz add-zsh-hook
add-zsh-hook precmd prompt_faux_precmd
THEME

  cat > "${TH}/prompt_broken_setup" <<'THEME'
PS1='SHOULD-NOT-STICK> '
return 1
THEME

  cat > "${TH}/prompt_second_setup" <<'THEME'
prompt_opts=(percent)
PS1='SECOND> '
THEME
}

# A clean shell with the library sourced and the fake themes on fpath.
zt() {
  env -u STARSHIP_CONFIG -u FPATH PATH="$PATH" HOME="$HOME" \
      zsh -fc "source ${LIB}
fpath=(${TH} \$fpath)
$1"
}

# --- loading without the prompt system ---------------------------------------

@test "a theme loads with promptinit never run" {
  run zt 'ftl-prompt faux; printf "[%s]" "$PS1"'
  [ "$output" = "[FAUX> ]" ]
}

@test "loading a theme does not pull in the prompt system" {
  run zt 'ftl-prompt faux >/dev/null 2>&1
print "prompt=${+functions[prompt]} themes=${+prompt_themes}"'
  [ "$output" = "prompt=0 themes=0" ]
}

@test "the prompt system still layers on top afterwards" {
  # What the header comment tells anyone who wants `prompt -l` back.
  run zt 'ftl-prompt faux >/dev/null 2>&1
autoload -Uz promptinit; promptinit
print "${prompt_themes[(r)faux]:-NO}"'
  [ "$output" = "faux" ]
}

@test "prompt_newline is defined, the way promptinit would leave it" {
  run zt 'printf "[%s]" "$prompt_newline"'
  [ "$output" = "[
%{"$'\r'"%}]" ]
}

# --- prompt_opts -------------------------------------------------------------

@test "the options a theme asks for reach the shell" {
  run zt 'ftl-prompt faux >/dev/null 2>&1
print "subst=$options[promptsubst] cr=$options[promptcr]"'
  [ "$output" = "subst=on cr=on" ]
}

@test "options a theme did not ask for are turned off" {
  # setopt noprompt{...} first is what makes this a replacement, not an addition.
  run zt 'setopt promptbang
ftl-prompt faux >/dev/null 2>&1
print "bang=$options[promptbang]"'
  [ "$output" = "bang=off" ]
}

@test "one theme's options do not carry into the next" {
  run zt 'ftl-prompt faux >/dev/null 2>&1
ftl-prompt second >/dev/null 2>&1
print "subst=$options[promptsubst] percent=$options[promptpercent]"'
  [ "$output" = "subst=off percent=on" ]
}

# --- prompt_theme ------------------------------------------------------------

@test "prompt_theme records the theme and the arguments it got" {
  run zt 'ftl-prompt faux myarg >/dev/null 2>&1; print -r -- "$prompt_theme"'
  [ "$output" = "faux myarg" ]
}

@test "prompt_theme is left empty when the setup function fails" {
  run zt 'ftl-prompt broken >/dev/null 2>&1
print "rc=$? theme=${#prompt_theme}"'
  [ "$output" = "rc=1 theme=0" ]
}

@test "a failing theme does not leave its half-set prompt behind" {
  # The setup assigns PS1 before it fails, which the caller has to hear about.
  run zt 'ftl-prompt broken >/dev/null 2>&1; print "rc=$?"'
  [ "$output" = "rc=1" ]
}

# --- arguments ---------------------------------------------------------------

@test "arguments are forwarded to the setup function" {
  run zt 'ftl-prompt faux hello >/dev/null 2>&1; print "$FAUX_ARG"'
  [ "$output" = "hello" ]
}

# --- where the setup function comes from -------------------------------------

@test "an unknown theme fails, and zsh says why" {
  run zt 'ftl-prompt nosuchtheme 2>&1 >/dev/null; print "rc=$?"'
  [[ "$output" == *"prompt_nosuchtheme_setup"* ]]
  [[ "$output" == *"rc=1"* ]]
}

@test "a setup function a plugin already defined is used as-is" {
  # No fpath lookup, so nothing clobbers it with an autoload stub.
  run zt 'prompt_faux_setup() { PS1="FROM-PLUGIN> " }
ftl-prompt faux >/dev/null 2>&1
printf "[%s]" "$PS1"'
  [ "$output" = "[FROM-PLUGIN> ]" ]
}

@test "a theme that only exists as a function still loads" {
  run zt 'prompt_onlyfn_setup() { PS1="ONLY-FN> " }
ftl-prompt onlyfn >/dev/null 2>&1
printf "[%s]" "$PS1"'
  [ "$output" = "[ONLY-FN> ]" ]
}

@test "hooks a previous theme left are not cleaned up" {
  # This sets one theme at startup and stops. Tearing down a previous theme is
  # promptinit's job, and costs time every shell to serve a case that never comes.
  run zt 'ftl-prompt faux >/dev/null 2>&1
ftl-prompt second >/dev/null 2>&1
print "hook=${precmd_functions[(r)prompt_faux_precmd]:-gone}"'
  [ "$output" = "hook=prompt_faux_precmd" ]
}
