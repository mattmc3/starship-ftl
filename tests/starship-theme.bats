#!/usr/bin/env bats
#
# Tests for themes/prompt_starship_setup, the promptinit theme.
#
# Mostly about config resolution, which README documents as a three-step search
# and is the part a user is most likely to get wrong.
#
# Every test clears FPATH as well as STARSHIP_CONFIG. Another
# prompt_starship_setup on fpath, or an exported starship config, otherwise
# decides the result and these measure the machine rather than this repo.

setup() {
  # Keep every cached starship answer inside this test, not in the real cache.
  export XDG_CACHE_HOME="${BATS_TEST_TMPDIR}/cache"
  if ! command -v starship >/dev/null 2>&1; then
    skip "starship is not installed"
  fi
  REPO="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  LIB="${REPO}/ftl-prompt.zsh"
  ZD="${BATS_TEST_TMPDIR}/zdot"
  XDG="${BATS_TEST_TMPDIR}/xdg"
  mkdir -p "${ZD}/themes" "${XDG}/starship"
  printf 'add_newline = false\nformat = "ZDOT>"\n' > "${ZD}/themes/mytheme.toml"
  printf 'add_newline = false\nformat = "XDG>"\n'  > "${XDG}/starship/mytheme.toml"
  printf 'add_newline = false\nformat = "DIRECT>"\n' > "${BATS_TEST_TMPDIR}/direct.toml"
}

# Load the theme and report where STARSHIP_CONFIG ended up.
resolve() {
  env -u STARSHIP_CONFIG -u FPATH PATH="$PATH" HOME="$HOME" \
      ZDOTDIR="$ZD" XDG_CONFIG_HOME="$XDG" \
      zsh -fc "source ${LIB}
autoload -Uz promptinit; promptinit
prompt starship $1 >/dev/null 2>&1
print \"\${STARSHIP_CONFIG:-unset}\""
}

# --- config resolution -------------------------------------------------------

@test "no argument leaves STARSHIP_CONFIG alone" {
  run resolve ""
  [ "$output" = "unset" ]
}

@test "a name resolves under ZDOTDIR/themes" {
  run resolve "mytheme"
  [ "$output" = "${ZD}/themes/mytheme.toml" ]
}

@test "a name falls back to XDG_CONFIG_HOME/starship" {
  rm "${ZD}/themes/mytheme.toml"
  run resolve "mytheme"
  [ "$output" = "${XDG}/starship/mytheme.toml" ]
}

@test "ZDOTDIR wins when both locations have the file" {
  run resolve "mytheme"
  [ "$output" = "${ZD}/themes/mytheme.toml" ]
}

@test "an unknown name leaves STARSHIP_CONFIG unset" {
  # Better than pointing starship at a path that does not exist.
  run resolve "nosuchtheme"
  [ "$output" = "unset" ]
}

@test "an explicit path argument is honoured" {
  run resolve "${BATS_TEST_TMPDIR}/direct.toml"
  [ "$output" = "${BATS_TEST_TMPDIR}/direct.toml" ]
}

@test "an explicit path beats a same-named file in the search locations" {
  # First entry in the search list wins.
  cp "${ZD}/themes/mytheme.toml" "${BATS_TEST_TMPDIR}/mytheme.toml"
  run resolve "${BATS_TEST_TMPDIR}/mytheme.toml"
  [ "$output" = "${BATS_TEST_TMPDIR}/mytheme.toml" ]
}

# --- what the theme sets -----------------------------------------------------

@test "the theme declares the prompt options it needs" {
  # cr, percent, sp and subst, per the prompt system's convention. promptinit
  # reads prompt_opts after the setup function returns.
  run env -u STARSHIP_CONFIG -u FPATH PATH="$PATH" HOME="$HOME" \
    ZDOTDIR="$ZD" XDG_CONFIG_HOME="$XDG" \
    zsh -fc "source ${LIB}
autoload -Uz promptinit; promptinit
functions[_check]='print \"opts=\$prompt_opts\"'
prompt_starship_setup >/dev/null 2>&1
print \"opts=\${(o)prompt_opts}\""
  [[ "$output" == *"cr"* ]]
  [[ "$output" == *"percent"* ]]
  [[ "$output" == *"sp"* ]]
  [[ "$output" == *"subst"* ]]
}

@test "the theme sets a prompt" {
  run env -u STARSHIP_CONFIG -u FPATH PATH="$PATH" HOME="$HOME" \
    ZDOTDIR="$ZD" XDG_CONFIG_HOME="$XDG" \
    zsh -fc "source ${LIB}
autoload -Uz promptinit; promptinit
prompt starship >/dev/null 2>&1
print \"ps1=\${PS1:+set}\""
  [ "$output" = "ps1=set" ]
}

@test "the theme refuses to load without starship and says why" {
  run env -i PATH=/usr/bin:/bin HOME="$HOME" \
    zsh -fc "source ${LIB}
autoload -Uz promptinit; promptinit
prompt starship 2>&1 >/dev/null"
  [[ "$output" == *"starship command not found"* ]]
}

@test "the theme file is named for the prompt system's convention" {
  # promptinit only autoloads prompt_<name>_setup from fpath. A differently named
  # file is invisible to it, which is not obvious from any error message.
  [ -f "${REPO}/themes/prompt_starship_setup" ]
}
