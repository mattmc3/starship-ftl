# Transient prompt prototypes

Two competing implementations of a transient left prompt for starship on Zsh,
built to be swapped in a live shell and compared. Background and citations are
in [../transient_prompt_plan.md](../transient_prompt_plan.md).

| File | What it is |
| --- | --- |
| `transient-common.zsh` | Shared widget-safety and starship rendering. Both prototypes source it |
| `transient-a.zsh` | Technique 1: truncate in `zle-line-finish`, deferred restore via `zle -F` |
| `transient-b.zsh` | Technique 2: wrap the editing session in `zle .recursive-edit` |
| `test-transient.zsh` | Drives one prototype through 7 cases in a real tmux pane |

## Try it

Needs `starship` and, for the harness, `tmux`.

Add a transient profile to your `starship.toml`:

```toml
[profiles]
transient = "[❯](bold green) "
```

Then, in an interactive shell, after your prompt is already set up:

```zsh
source prototypes/transient-a.zsh
ftl-transient-a-on
# ... use the shell ...
ftl-transient-a-off

source prototypes/transient-b.zsh
ftl-transient-b-on
```

Both provide a matching `-off` so you can switch techniques without restarting.
Load order matters: enable these after your theme is set, because the full
prompt is snapshotted at enable time.

Optional:

```zsh
zstyle ':ftl-prompt:' transient-profile  transient   # default
zstyle ':ftl-prompt:' transient-rprofile rtransient  # default: no right prompt
```

## Automated comparison

```zsh
zsh prototypes/test-transient.zsh A
zsh prototypes/test-transient.zsh B
```

## Measured results

zsh 5.9.2, starship 1.26.0, macOS, real tmux pane. Both prototypes use the
identical common layer, so differences are the technique.

| Case | A (`zle-line-finish`) | B (`recursive-edit`) |
| --- | --- | --- |
| 1. Normal commands | Pass | Pass |
| 2. Ctrl-C on a typed line | Pass | Pass |
| 3. Completion menu, then Ctrl-C | Pass | Pass |
| 4. ESC x, then Ctrl-C | Pass | Pass |
| 5. Background job notification | Pass, `[1] + done` appears promptly | **Never appears** |
| 6. `$?` after Ctrl-C | Pass, `130` | **`1`, wrong** |
| 7. Foreign widgets still fire | Pass | Pass |

Both of B's predicted failures reproduced. A produced no failure in any of the
seven cases.

### Reading the results

B's two defects are behavioral. A missing job-completion notification is silence
where the shell promised output, and a wrong `$?` after Ctrl-C corrupts data that
every conditional downstream depends on.

A has no known defect in these cases. **Recommend A**, which is also the
conclusion romkatv reached in 2020, now with measurements against this specific
code rather than by reputation.

Caveat on scope: seven cases is not a proof. romkatv's objection to this
technique is that it truncates for lines that were never accepted, and the cases
here do not exhaust the widgets that could do that. What they do establish is
that the deferred restore recovers in every case tried, including the two he
named specifically.

#### Retracted: the "stray line" artifact

An earlier version of this document reported that A left a stray bare prompt
line after `ESC x` then Ctrl-C. That was wrong, twice over, and the way it was
wrong is worth keeping.

The harness session was running `viins`, because zsh selects vi mode when
`$EDITOR` looks like vi and the harness had not yet pinned the keymap. In
`viins`, `ESC` switches to `vicmd` and `x` on an empty line deletes nothing, so
Ctrl-C landed on a plain empty line rather than on `execute-named-cmd` at all.
The named widget was never involved.

And the bare line is not a transient-prompt behavior. Ctrl-C on an empty line
leaves a bare prompt line in scrollback in stock zsh with no prototype loaded:

```
BASE%
BASE% echo done
done
BASE%
```

All the prototype does is render that line short instead of long, which is
exactly what a transient prompt is supposed to do.

Two lessons. Pin the keymap in any zle test, or you are testing keybindings you
did not choose. And capture a baseline without your code loaded before calling
any terminal behavior a defect.

Note B's status bug is not a flaw in this prototype. oh-my-posh ships the same
technique and carries the same bug as a `TODO (fix)` in its own source. It
follows from `zle .send-break` and there is no obvious fix.

## Notes for whoever productionizes this

Things that cost time here and are easy to trip over again.

**Snapshot the full prompt at enable time, never in `precmd`.** The deferred
restore fires when zle is next active, which is *after* `precmd`. At `precmd`
time `PROMPT` still holds the short value, so snapshotting there captures the
transient prompt as the full one and the prompt never comes back.

**Render off the keypress path.** One `starship prompt --profile` call per
command in `precmd`, cached in a variable. Rendering inside the widget puts a
process spawn between the keypress and the redraw.

**`add_newline` applies to profiles too.** It defaults to true and prepends a
blank line, which would put an empty line above every committed command. The
common layer strips leading newlines so users do not have to set
`add_newline = false`.

**A missing profile is not an error exit.** starship 1.26 prints a diagnostic
on stderr, an empty prompt on stdout, and exits 0. Probe stderr, not `$?`.
`_ftl_tp_profile_ok` does this once at enable time and falls back to `%# `.

**Never bind a widget you did not create.** `zle -N send-break mine` deletes
whatever a plugin already installed, and `zle .send-break` afterwards skips
their wrapper permanently. `_ftl_tp_wrap_widget` aliases the existing binding to
a private name and delegates to that. Use `add-zle-hook-widget` for the real
hooks (`zle-line-init`, `zle-line-finish`) and the wrapper only for actual
widgets like `send-break`. This is what blocked starship#4205 in review.

**Ctrl-C does not go through `send-break`.** It arrives as SIGINT, which is why
A needs a `TRAPINT` as well as the widget wrapper. A test that presses Ctrl-C
and checks a `send-break` counter is testing nothing. Bind a key explicitly.

**Pin the keymap in tests.** zsh selects `viins` when `$EDITOR` looks like vi,
and in `viins` `^G` is `list-expand`, not `send-break`. The harness does
`bindkey -e` for this reason.

## Not yet tested

- Interaction with `ftl-prompt`'s own instant prompt on the **first command** of
  a session. `_ftl_prompt_clear` does a saved-cursor restore plus `\e[J` erase
  anchored to a position saved before the instant prompt was drawn, and a
  transient redraw lands between the save and the erase. The harness starts
  from a settled prompt and does not cover this. See the plan document.
- `zsh-vi-mode`, which wraps `zle-line-init` and forced a documented workaround
  in oh-my-posh. Expected to hit B much harder than A.
- Whether any builtin widget makes A truncate for a line that was never
  accepted, which is romkatv's actual objection to the technique. The two cases
  he named are covered and both pass, but `execute-last-named-cmd`,
  `history-incremental-search-backward`, `read-command` and vi
  operator-pending states are unswept.
- Multi-line commands and continuation prompts.
