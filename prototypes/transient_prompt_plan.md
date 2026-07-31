# Transient left prompt for starship: research and plan

Status: research notes, no implementation yet.

## What we want

Starship has no transient prompt on Zsh. After you run a command, the full
prompt stays in scrollback. A transient prompt replaces the committed prompt
with a short one, so history reads as a clean list of commands and the full
prompt only ever appears on the line you are editing.

Upstream tracking issue: [starship#888][888], open since January 2020.

Fish, PowerShell (via oh-my-posh), and Cmd (via Clink) have this. Zsh does not,
because Zsh makes it hard.

## The two approaches

Both come from [romkatv's comment][romkatv-888], which is still the best summary
of the problem. He is the powerlevel10k author, so this is first-hand.

### Approach 1: truncate in `zle-line-finish`, restore in `precmd`

Reference post: [workers/2019/msg00944][w944].

`zle-line-finish` fires when the line editor is done with a line. Swap `PROMPT`
to the short version, `zle reset-prompt`, and the committed line in scrollback
gets the short prompt. Restore the full prompt before the next line is edited.

Failure mode romkatv names: Ctrl-C out of a modal widget. `zle-line-finish`
fires, so the prompt truncates, but the line was never actually accepted. You
get a truncated prompt where the full one belongs. See
[powerlevel10k#321][p10k321].

His own fix, described but never posted: stop trying to prevent the wrong
truncation, and instead recover fast once you can tell it was wrong. That needs
a deferred callback, which he does with `zle -F` on a file descriptor that is
always ready.

### Approach 2: wrap the whole editing session in `recursive-edit`

Reference post: [users/2019/msg00633][u633], "RFC: Generalized transient_rprompt".
Full code from that post:

```zsh
zle-line-init() {
  emulate -L zsh

  [[ $CONTEXT == start ]] || return 0

  while true; do
    zle .recursive-edit
    local -i ret=$?
    [[ $ret == 0 && $KEYS == $'\4' ]] || break
    [[ -o ignore_eof ]] || exit 0
  done

  local saved_prompt=$PROMPT
  local saved_rprompt=$RPROMPT
  PROMPT='%# '
  RPROMPT=''
  zle .reset-prompt
  PROMPT=$saved_prompt
  RPROMPT=$saved_rprompt

  if (( ret )); then
    zle .send-break
  else
    zle .accept-line
  fi
  return ret
}

zle -N zle-line-init
```

Shorter and easier to reason about. Its failure mode is structural: because the
whole session runs inside `recursive-edit`, background job notifications are
held until the line finishes, as though `no_notify` were set. romkatv flags this
at the bottom of that same post.

### Zsh bugs both approaches trip

From the same comment, with romkatv's own characterization:

1. [users/2019/msg00435][u435] - segfault, workaround exists
2. [workers/2019/msg00941][w941] - segfault, workaround exists
3. [workers/2020/msg00024][w24] - `zle reset-prompt` from a trap prints a stray
   `n` at column 1. No workaround found. Does not crash.

Bug 3 is worth re-testing on modern Zsh; see open questions.

## Who ships which approach

| Project | Technique | Widget binding | Short prompt from | Size | Status |
| --- | --- | --- | --- | --- | --- |
| [powerlevel10k][p10k] | 1, hardened | Wraps every zle widget | Own prompt engine | 338 KB `p10k.zsh` | Shipping, the reference implementation |
| [oh-my-posh][omp-init] | 2 | `_omp_create_widget`, backs up and decorates | `omp print transient` | 748-line `omp.zsh` | Shipping |
| [olets/zsh-transient-prompt][olets] 1.0.1 | 1 | `zle -N`, clobbers | `$TRANSIENT_PROMPT_*` vars | 114 lines | Shipping, prompt-agnostic |
| [subnut gist][subnut] | 1 | `zle -N`, clobbers | `$TRANSIENT_PROMPT` var | ~30 lines | Gist, olets generalizes it |
| [starship#4205][pr4205] | 2 | `zle -N` plus deletion | starship transient config | PR | Open since 2022, not merged |
| DeadKper, [discussion#5950][d5950] | 1 | `add-zle-hook-widget`, safe | `starship prompt --profile` | ~20 lines | User snippet |
| mikecsmith, [comment][mikec] | 1 | Custom widgets | `starship prompt` calls | ~1 screen | User snippet, self-described untested |

Technique 1 is `zle-line-finish` truncate plus deferred restore. Technique 2 is
`zle-line-init` wrapping `.recursive-edit`.

Reading the table: the two shipping, battle-tested implementations disagree on
technique, so neither choice is disqualifying. The split that actually predicts
quality is the widget-binding column, not the technique column. Both shipping
projects decorate existing widgets; every implementation that clobbers with a
bare `zle -N` is a snippet or a single-purpose plugin, and the one that clobbered
inside a PR to a major project got blocked on exactly that.

Note also that the two most convenient references pull in opposite directions:
olets has the technique we want but the binding we do not, and DeadKper has the
binding and the `--profile` rendering but none of the Ctrl-C recovery. The
implementation here is olets' body with DeadKper's binding and rendering.

`olets` and `subnut` are the distilled version of what romkatv described but
never published. That matters: the "hairy" part of his solution is wrapping
every widget, and these implementations skip it. They wrap only `send-break`
and install a `TRAPINT`. It is far less code than "impenetrable" suggests.

oh-my-posh source, for approach 2 in production:
[omp.zsh `_omp_zle-line-init`][omp-init]. Note their own `TODO (fix)` comment:
on interrupt they call `zle .send-break`, which leaves `$?` at 1 instead of 130.
That is the same class of bug the starship PR was criticized for.

## Empirical findings

Tested on this machine: zsh 5.9.2 (Homebrew, aarch64-apple-darwin25.4.0),
starship 1.26.0, driven through a real tmux pane so the terminal behaves.

### Approach 1 works, and the corner case is cosmetic

Minimal approach-1 implementation, modeled on olets: full prompt
`FULLPROMPT-%~ %#` with `RPROMPT='[RIGHT]'`, transient `SHORT> `.

Two normal commands, exactly right:

```
SHORT> echo one
one
SHORT> echo two
two
FULLPROMPT-/path/to/cwd %                            [RIGHT]
```

Corner cases, all four run in one session:

| Case | Result |
| --- | --- |
| Ctrl-C on a typed line | Correct. `SHORT> echo hello` committed, full prompt returns |
| Completion menu (`ls --<TAB>`) then Ctrl-C | Correct. Line committed as `SHORT> ls --color=`, full prompt returns |
| ESC x (`execute-named-cmd`) then Ctrl-C | Correct. Nothing committed, full prompt returns |
| Normal command after all of the above | Correct. Fully recovered, no lasting damage |

Both corner cases romkatv named specifically are handled. The deferred restore
brings the full prompt back every time.

An earlier version of this document reported a stray scrollback line in the
`ESC x` case. That was a testing error and is retracted; details in
[prototypes/README.md](prototypes/README.md). Two causes, both mine: the test
shell was in `viins` rather than emacs, so `ESC x` never reached
`execute-named-cmd`, and the bare line it produced turns out to be what stock
zsh does for Ctrl-C on an empty line with no prompt plugin loaded at all.

This does not mean the technique is proven. romkatv's objection is that it
truncates for lines that were never accepted, and seven cases do not exhaust the
widgets that might do that. It means the two cases he named do not break it.

The mechanism that makes it recoverable: `sysopen -r -o cloexec -u fd /dev/null`
gives a descriptor that is always readable, so `zle -F $fd handler` fires at the
next point zle is active. That is the deferred restore, and it is 4 lines.

### starship has native support for the rendering half

Verified on starship 1.26.0. `starship prompt --profile <name>` is a documented
flag:

```
--profile <PROFILE>
    Print the prompt with the specified profile name (instead of the standard left prompt)
```

With `starship.toml`:

```toml
[profiles]
transient = "$character"
```

`starship prompt --profile transient` renders just the character. Confirmed
working locally.

This is the part the research reframes. Every discussion of this problem treats
"what do I render for the short prompt" as the user's problem, hardcoding `%# `
or similar. Starship already solves it, configurably, and only DeadKper's
snippet uses it. A starship-specific implementation gets this for free.

## Prototypes

Both techniques are implemented in [prototypes/](prototypes/), sharing one
common layer so an A/B comparison measures the technique and not the plumbing.
Results, and the notes worth keeping, are in
[prototypes/README.md](prototypes/README.md).

Summary of the measured comparison:

| Case | A (`zle-line-finish`) | B (`recursive-edit`) |
| --- | --- | --- |
| Normal commands, Ctrl-C, completion menu | Pass | Pass |
| ESC x then Ctrl-C | Pass | Pass |
| Background job notification | Pass | Never appears |
| `$?` after Ctrl-C | `130` | `1`, wrong |
| Foreign widgets still fire | Pass | Pass |

A produced no failure in any of the seven cases. B's two predicted defects both
reproduced, and both are behavioral: silence where the shell promised output,
and a corrupted exit status. Recommend A.

## Is romkatv wrong?

No, but his comment is dated in two ways.

He is right that neither approach is clean, that approach 1 mis-truncates on
Ctrl-C out of modal widgets, and that approach 2 breaks job notifications. All
three still hold. The starship PR that ignored this got the exact bugs he
predicted.

What has changed since January 2020:

- His unpublished fix has been independently rebuilt and shipped, twice, in
  under 100 lines. "Impenetrable" describes p10k's code, not the technique.
- The residual failure on approach 1 measures as one stray scrollback line, not
  a broken prompt. Worth confirming against more widgets, but it is a cosmetic
  bug, and a documented cosmetic bug is shippable.
- starship `--profile` means the short prompt no longer has to be hardcoded.

So the honest read: approach 1 plus the `zle -F` recovery is good enough to
ship with a known-issues note. There is no simple approach nobody thought of.
Both options are still compromises, and the compromise in approach 1 is the
cheaper one.

## Recommended plan

Approach 1, following olets, with starship `--profile` for rendering.

1. Add `ftl-prompt-transient` as opt-in, off by default. It is a separate
   feature from instant prompt and should not be forced on anyone.
2. Render via `starship prompt --profile transient`, with the profile name
   configurable through `zstyle ':ftl-prompt:' transient-profile`, matching the
   existing `cursor` zstyle.
3. Precompute the transient prompt string in `precmd`, not in
   `zle-line-finish`. Shelling out to starship inside the finish widget puts a
   subprocess between keypress and redraw. DeadKper's updated snippet does this
   for the same reason.
4. Use the olets mechanism verbatim in shape: `zle-line-finish` widget,
   `send-break` wrapper, `TRAPINT`, `sysopen` on `/dev/null` plus `zle -F` for
   the deferred restore.
5. Decorate existing widgets instead of clobbering them. `zle -N zle-line-finish`
   overwrites whatever a framework already bound. Use `add-zle-hook-widget`, or
   oh-my-posh's `_omp_create_widget` backup-and-wrap pattern. This is what
   sank starship#4205 in review, and our target audience runs plugin managers.
6. Do not touch `precmd_functions` by assignment. The test config here did
   `precmd_functions=(_tp_precmd)`, which is fine for a test and wrong for a
   plugin. Use `add-zsh-hook`.
7. Document the ESC-x-then-Ctrl-C stray line in the README known issues, in the
   same voice as the existing experimental warning.

### Interaction with the instant prompt, must test

Unresolved and specific to this project. `ftl-prompt` already installs a
`precmd` hook (`_ftl_prompt_clear`) and suspends `prompt_cr`/`prompt_sp` until
that hook runs. The transient feature adds a `zle-line-finish` widget. On the
very first command of a session both are live at once, and the ordering is:
first `zle-line-finish` (transient truncation) then first `precmd`
(`_ftl_prompt_clear`, which does a saved-cursor restore and `\e[J` erase).

That erase is anchored to the position saved before the instant prompt was
drawn. A transient redraw between the save and the erase is exactly the kind of
thing that will misplace it. Test the first command specifically, not just the
steady state.

## Open questions

- Does bug 3 (`workers/2020/msg00024`, stray `n`) still reproduce on 5.9.x? An
  attempt here was inconclusive because driving menu completion through `zpty`
  did not engage the menu. Retest through tmux, the way the corner cases were
  tested.
- Which other builtin widgets leave the stray line? ESC-x was found by trying
  the two romkatv named. Worth sweeping `execute-named-cmd`,
  `execute-last-named-cmd`, `history-incremental-search-backward`, `read-command`,
  and vi operator-pending states.
- Interaction with `zsh-vi-mode`, which wraps `zle-line-init` and forced a
  documented workaround in oh-my-posh ([oh-my-posh#5992][omp5992]).
- Right prompt: `setopt transient_rprompt` is builtin and already handles
  RPROMPT. Check whether it conflicts with clearing RPROMPT ourselves.

[888]: https://github.com/starship/starship/issues/888
[romkatv-888]: https://github.com/starship/starship/issues/888#issuecomment-580127661
[w944]: https://www.zsh.org/mla/workers//2019/msg00944.html
[u633]: https://www.zsh.org/mla/users/2019/msg00633.html
[u435]: https://www.zsh.org/mla/users/2019/msg00435.html
[w941]: https://www.zsh.org/mla/workers//2019/msg00941.html
[w24]: https://www.zsh.org/mla/workers//2020/msg00024.html
[p10k321]: https://github.com/romkatv/powerlevel10k/issues/321
[olets]: https://github.com/olets/zsh-transient-prompt
[subnut]: https://gist.github.com/subnut/3af65306fbecd35fe2dda81f59acf2b2
[pr4205]: https://github.com/starship/starship/pull/4205
[d5950]: https://github.com/starship/starship/discussions/5950
[omp-init]: https://github.com/JanDeDobbeleer/oh-my-posh/blob/main/src/shell/scripts/omp.zsh
[omp5992]: https://github.com/JanDeDobbeleer/oh-my-posh/issues/5992
[p10k]: https://github.com/romkatv/powerlevel10k
[mikec]: https://github.com/starship/starship/issues/888#issuecomment-3908148100
