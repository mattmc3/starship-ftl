_default:
    @just --list

test:
    bats --print-output-on-failure tests/

# eg: just test-file internals
test-file name:
    bats --print-output-on-failure tests/{{ name }}.bats

lint:
    #!/usr/bin/env zsh
    for f in *.zsh themes/prompt_*_setup; do
      zsh -n $f || exit 1
      print -r -- "ok  $f"
    done

check: lint test

# Shell with the plugin loaded and nothing of yours, for the cases bats cannot reach
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
    " > $rc
    ZDOTDIR=${rc:h} zsh -i
