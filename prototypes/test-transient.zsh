#!/usr/bin/env zsh
#
# test-transient.zsh A|B
#
# Drives a prototype through a real tmux pane and prints what the terminal
# actually shows. tmux rather than zpty because menu completion needs a terminal
# that reports a real size and capabilities.
#
# Cases 5, 6 and 7 are the ones that separate the two techniques. Case 7 is the
# plugin-coexistence check: a foreign widget is bound before the prototype
# loads, and it must still fire afterwards.

emulate -L zsh

local which=${1:-A}
local lower=${which:l}
local proto_dir=${0:A:h}
local work=${TMPDIR:-/tmp}/ftl-tp-test-$lower
local sess=ftltp$lower

(( $+commands[tmux] )) || { print -ru2 -- "need tmux"; return 1 }
(( $+commands[starship] )) || { print -ru2 -- "need starship"; return 1 }

rm -rf $work; mkdir -p $work

cat > $work/starship.toml <<'TOML'
add_newline = false
format = "$directory$character"

[profiles]
transient = "[>](bold green) "

[directory]
format = "[$path]($style) "

[character]
success_symbol = "[FULL%](bold blue)"
error_symbol = "[FULL!](bold red)"
TOML

cat > $work/.zshrc <<RC
export STARSHIP_CONFIG=$work/starship.toml
eval "\$(starship init zsh)"

# Pin the keymap. zsh picks viins when \$EDITOR looks like vi, and in viins
# ^G is list-expand rather than send-break, which makes case 7 silently test
# nothing at all.
bindkey -e
bindkey '^G' send-break

# --- foreign plugin, loaded BEFORE the prototype ---------------------------
# Stands in for anything that already owns these widgets. Both must keep
# working after the prototype wraps them.
typeset -g FOREIGN_BREAK=0 FOREIGN_FINISH=0
_foreign_send_break() { (( ++FOREIGN_BREAK )); zle .send-break }
zle -N send-break _foreign_send_break
autoload -Uz add-zle-hook-widget
_foreign_finish() { (( ++FOREIGN_FINISH )) }
add-zle-hook-widget zle-line-finish _foreign_finish

source $proto_dir/transient-$lower.zsh
ftl-transient-$lower-on
RC

tmux kill-session -t $sess 2>/dev/null
tmux new-session -d -s $sess -x 100 -y 40 "ZDOTDIR=$work $(command -v zsh) -i"
sleep 3

show() { tmux capture-pane -p -t $sess | grep -v '^$' | tail -${1:-6} }
send() { tmux send-keys -t $sess "$@" }

print -r -- "########## technique $which ##########"

print -r -- "
### 1. two normal commands (expect '>' on committed lines, FULL% live)"
send 'echo one' Enter; sleep 1
send 'echo two' Enter; sleep 1
show 6

print -r -- "
### 2. Ctrl-C on a typed line"
send 'echo aborted'; sleep 0.5
send C-c; sleep 1.5
show 4

print -r -- "
### 3. completion menu then Ctrl-C"
send 'ls --'; sleep 0.5
send Tab; sleep 2
send C-c; sleep 2
show 4

print -r -- "
### 4. ESC x (execute-named-cmd) then Ctrl-C"
send Escape; send 'x'; sleep 1
send C-c; sleep 2
show 5

print -r -- "
### 5. background job notification (technique B suppresses this)"
send 'clear' Enter; sleep 1
send '{ sleep 1; } &' Enter; sleep 3
print -r -- "--- pane 3s after backgrounding, looking for a 'done' line ---"
show 8

print -r -- "
### 6. exit status after Ctrl-C (expect 130, B gives 1)"
send 'clear' Enter; sleep 1
send 'echo nope'; sleep 0.5
send C-c; sleep 1
send 'echo "status=$?"' Enter; sleep 1.5
show 5

print -r -- "
### 7. foreign widgets still fire after wrapping"
# Ctrl-C is delivered as a signal and never reaches the send-break widget, so
# it proves nothing here. Ctrl-G is the key actually bound to send-break.
send 'clear' Enter; sleep 1
send 'echo x'; sleep 0.3
send C-g; sleep 1.5
send 'echo "break=$FOREIGN_BREAK finish=$FOREIGN_FINISH"' Enter; sleep 1.5
show 5
print -r -- "--- break must be >0 (our wrapper delegated), finish must be >0 ---"

tmux kill-session -t $sess 2>/dev/null
print -r -- "
########## end $which ##########"
