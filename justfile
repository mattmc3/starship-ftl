_default:
    @just --list

# Run the whole bats suite
test:
    bats --print-output-on-failure tests/

# Run one bats file, eg: just test-file internals
test-file name:
    bats --print-output-on-failure tests/{{ name }}.bats

# Parse every zsh source file without running it
lint:
    #!/usr/bin/env zsh
    for f in *.zsh themes/prompt_*_setup; do
      zsh -n $f || exit 1
      print -r -- "ok  $f"
    done

# lint plus the full suite, what CI runs
check: lint test

# Report the tool versions the suite depends on
tools:
    #!/usr/bin/env zsh
    for t in zsh bats starship just; do
      if (( $+commands[$t] )); then
        print -r -- "${(r:10:)t} $($t --version 2>&1 | head -1)"
      else
        print -r -- "${(r:10:)t} MISSING"
      fi
    done

# Try the prompt in a throwaway interactive shell, no config of yours involved
demo config="single-line":
    #!/usr/bin/env zsh
    local rc=$(mktemp -d)/.zshrc
    print -r -- "
      export STARSHIP_CONFIG=${PWD}/examples/{{ config }}.toml
      source ${PWD}/ftl-prompt.zsh
      ftl-prompt starship
      source ${PWD}/ftl-transient.zsh
      ftl-transient on
      bindkey -e
      print -r -- 'starship-ftl demo. exit to leave.'
    " > $rc
    ZDOTDIR=${rc:h} zsh -i
