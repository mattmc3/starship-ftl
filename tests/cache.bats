#!/usr/bin/env bats
#
# Tests for ftl-cache.zsh and the two callers that use it.
#
# The point is that starship is not spawned twice for the same answer, so most
# of these count spawns rather than read output: a fake starship writes one line
# per call to $STARSHIP_SPY. The rest cover invalidation, one per stamp input,
# since a cache that misses an edited config is the failure to avoid.

setup() {
  # Keep every cached starship answer inside this test, not in the real cache.
  export XDG_CACHE_HOME="${BATS_TEST_TMPDIR}/cache"
  REPO="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  LIB="${REPO}/ftl-prompt.zsh"
  TLIB="${REPO}/ftl-transient.zsh"
  FIX="${BATS_TEST_DIRNAME}/fixtures"

  BIN="${BATS_TEST_TMPDIR}/bin"
  CFG="${BATS_TEST_TMPDIR}/starship.toml"
  SPY="${BATS_TEST_TMPDIR}/spy"
  mkdir -p "$BIN"
  printf 'add_newline = false\nformat = "FAKE>"\n\n[profiles]\ntransient = "x"\n' > "$CFG"

  # Enough of starship for both callers: an init that ends in the PROMPT2
  # command substitution the theme rewrites, a continuation, and a profiles
  # table. Every call is recorded.
  cat > "${BIN}/starship" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STARSHIP_SPY"
case "$1 ${2:-}" in
  "init zsh")
    printf 'setopt promptsubst\n'
    printf "PROMPT='\$(%s prompt)'\n" "$0"
    printf 'PROMPT2="$(%s prompt --continuation)"\n' "$0"
    exit 0 ;;
esac
case "$*" in
  "prompt --continuation")  printf 'CONT> '; exit 0 ;;
  "print-config profiles")
    # Honour the config, so a config without profiles reads as having none.
    grep -q '\[profiles\]' "$STARSHIP_CONFIG" \
      && printf 'transient = "x"\nrtransient = "y"\n'
    exit 0 ;;
esac
printf 'FAKE>'
FAKE
  chmod +x "${BIN}/starship"
  : > "$SPY"
}

# Load the theme in a clean shell, with the fake starship and fake config.
theme() {
  env -u FPATH PATH="${BIN}:${PATH}" HOME="$HOME" \
      XDG_CACHE_HOME="$XDG_CACHE_HOME" STARSHIP_CONFIG="$CFG" STARSHIP_SPY="$SPY" \
      zsh -fc "source ${LIB}
${1:-}
ftl-prompt starship >/dev/null 2>&1
${2:-}"
}

# Load ftl-transient in a clean shell, with the fake starship and fake config.
transient() {
  env -u FPATH PATH="${BIN}:${PATH}" HOME="$HOME" \
      XDG_CACHE_HOME="$XDG_CACHE_HOME" STARSHIP_CONFIG="$CFG" STARSHIP_SPY="$SPY" \
      zsh -fc "source ${TLIB} || exit 1
$1"
}

spy_count() { wc -l < "$SPY" | tr -d ' '; }

# --- the theme ---------------------------------------------------------------

@test "the first load spawns starship, the second spawns none" {
  theme
  first="$(spy_count)"
  [ "$first" -ge 2 ]

  : > "$SPY"
  theme
  [ "$(spy_count)" -eq 0 ]
}

@test "the cached init resolves PROMPT2 instead of leaving a subshell in it" {
  theme
  cache="${XDG_CACHE_HOME}/starship-ftl/starship-init.zsh"
  [ -f "$cache" ]
  grep -q 'PROMPT2=' "$cache"
  ! grep -q 'PROMPT2="\$(' "$cache"
}

@test "a cached load still sets the prompt it would have set live" {
  run theme '' 'print "P2=$PROMPT2"'
  [ "$output" = "P2=CONT> " ]

  run theme '' 'print "P2=$PROMPT2"'
  [ "$output" = "P2=CONT> " ]
}

@test "the theme works when the cache directory cannot be created" {
  run env -u FPATH PATH="${BIN}:${PATH}" HOME="$HOME" \
      XDG_CACHE_HOME=/proc/nonexistent-ftl STARSHIP_CONFIG="$CFG" STARSHIP_SPY="$SPY" \
      zsh -fc "source ${LIB}
ftl-prompt starship >/dev/null 2>&1
print \"P1=\${PROMPT:+set}\""
  [ "$output" = "P1=set" ]
}

# --- invalidation ------------------------------------------------------------

@test "editing the config invalidates the cache" {
  theme
  : > "$SPY"

  printf 'add_newline = false\nformat = "EDITED>"\nmore = "padding"\n' > "$CFG"
  theme
  [ "$(spy_count)" -ge 2 ]
}

@test "replacing the starship binary invalidates the cache" {
  theme
  : > "$SPY"

  printf '\n# changed\n' >> "${BIN}/starship"
  theme
  [ "$(spy_count)" -ge 2 ]
}

@test "a config appearing where there was none invalidates the cache" {
  # theme() reads $CFG, so pointing it at a path that does not exist yet is how
  # the absent-config case gets cached in the first place.
  CFG="${BATS_TEST_TMPDIR}/later.toml"
  theme
  : > "$SPY"

  printf 'add_newline = false\nformat = "LATER>"\n' > "$CFG"
  theme
  [ "$(spy_count)" -ge 2 ]
}

@test "a cache file with a foreign stamp is not reused" {
  theme
  cache="${XDG_CACHE_HOME}/starship-ftl/starship-init.zsh"
  printf '# v1 not-a-real-stamp\nPROMPT2="POISONED"\n' > "$cache"

  run theme '' 'print "P2=$PROMPT2"'
  [ "$output" = "P2=CONT> " ]
}

# --- opting out --------------------------------------------------------------

@test "cache no runs live every time and writes nothing" {
  theme "zstyle ':starship-ftl:' cache no"
  first="$(spy_count)"
  [ "$first" -ge 2 ]

  : > "$SPY"
  theme "zstyle ':starship-ftl:' cache no"
  [ "$(spy_count)" -ge 2 ]
  [ ! -f "${XDG_CACHE_HOME}/starship-ftl/starship-init.zsh" ]
}

# --- transient profiles ------------------------------------------------------

@test "profile names are cached, and the cached list matches the live one" {
  run transient '_ftl_starship_profile_names_live'
  live="$output"
  [ "$live" != "" ]

  : > "$SPY"
  run transient '_ftl_starship_profile_names'
  [ "$output" = "$live" ]

  : > "$SPY"
  run transient '_ftl_starship_profile_names'
  [ "$output" = "$live" ]
  [ "$(spy_count)" -eq 0 ]
}

@test "editing the config invalidates the cached profile names" {
  transient '_ftl_starship_profile_names' >/dev/null
  : > "$SPY"

  printf 'add_newline = false\nformat = "EDITED>"\nmore = "padding"\n' > "$CFG"
  transient '_ftl_starship_profile_names' >/dev/null
  [ "$(spy_count)" -ge 1 ]
}

@test "a config with no profiles caches an empty answer and stays empty" {
  run transient '_ftl_starship_profile_names; print "rc=$?"'
  [ "${lines[0]}" = "transient" ]

  # An empty answer is still an answer, so it has to cache and read back empty
  # rather than as one blank line.
  CFG="${BATS_TEST_TMPDIR}/none.toml"
  printf 'add_newline = false\n' > "$CFG"
  run transient '_ftl_starship_profile_names; print "rc=$?"'
  [ "$output" = "rc=0" ]

  run transient '_ftl_starship_profile_names; print "rc=$?"'
  [ "$output" = "rc=0" ]
}

# --- the stamp itself --------------------------------------------------------

@test "the stamp covers the starship binary and the config path" {
  run transient '_ftl_cache_stamp && print -r -- $REPLY'
  [[ "$output" == *"${BIN}/starship"* ]]
  [[ "$output" == *"${CFG}"* ]]
}

@test "the stamp records a missing config as missing rather than skipping it" {
  run env -u FPATH PATH="${BIN}:${PATH}" HOME="$HOME" \
      XDG_CACHE_HOME="$XDG_CACHE_HOME" STARSHIP_CONFIG="${BATS_TEST_TMPDIR}/absent.toml" \
      zsh -fc "source ${TLIB} || exit 1
_ftl_cache_stamp && print -r -- \$REPLY"
  [[ "$output" == *"absent.toml:-"* ]]
}

# --- against the real starship -----------------------------------------------

@test "the baked PROMPT2 is what real starship renders for the same config" {
  if ! command -v starship >/dev/null 2>&1; then
    skip "starship is not installed"
  fi
  live="$(STARSHIP_CONFIG="${FIX}/minimal.toml" starship prompt --continuation)"

  run env -u FPATH PATH="$PATH" HOME="$HOME" \
      XDG_CACHE_HOME="$XDG_CACHE_HOME" STARSHIP_CONFIG="${FIX}/minimal.toml" \
      zsh -fc "source ${LIB}
ftl-prompt starship >/dev/null 2>&1
printf '%s' \"\$PROMPT2\""
  [ "$output" = "$live" ]
}
