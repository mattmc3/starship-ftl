# starship-ftl

> A faster-than-light drive for Starship Zsh prompts

> [!WARNING]
> This is experimental. Prompt drawing is full of edge cases we haven't seen
> yet, and some we may not be able to solve for. If it works for your prompt,
> awesome! If it doesn't, file a bug report and include the starship.toml
> that isn't working. We may not be able to address every edge case.

[Starship][starship] renders a prompt in milliseconds, but you still stare at
an empty screen while the rest of your `.zshrc` loads. starship-ftl draws your
prompt before the rest of your config runs, then swaps in the real one when
loading finishes. Startup does the same work as before, it just stops making
you wait to see something.

The technique comes from [romkatv][romkatv]'s [instant-zsh][instant-zsh] gist,
the same idea behind powerlevel10k's instant prompt.

## Features

- Prompt appears immediately, before plugins and completions load
- Anything printed during startup, stdout and stderr, is captured
  and replayed above the real prompt instead of being erased
- _Hopefully_ no flickering: the swap happens in a single write bracketed by
  synchronized update marks, and the stray partial-line mark is suppressed
  while loading
- Allows you to also set your cursor style up front instead of waiting for
  your config to load
- Works with starship out of the box, or with any `promptinit` theme you build
- Optional transient prompt: finished commands collapse to a short prompt

## Installation

### Install with a plugin manager

With [antidote][antidote], add to the top of your `.zsh_plugins.txt`:

```
mattmc3/starship-ftl post:"ftl-prompt starship"
```

If you want to enable the transient prompt as well, use this:

```
mattmc3/starship-ftl post:"ftl-prompt starship; ftl-transient on"
```

### Manual installation

If you don't use a plugin manager, you can clone and source this manually:

```zsh
git clone https://github.com/mattmc3/starship-ftl ${ZDOTDIR:-$HOME}/.starship-ftl
source ${ZDOTDIR:-$HOME}/.starship-ftl/starship-ftl.plugin.zsh
```

Then, at the very top of your `.zshrc`, after making sure starship is in your path:

```zsh
# .zshrc
path=(/path/to/starship/bin $path)
source /path/to/starship-ftl/starship-ftl.plugin.zsh
ftl-prompt starship  # show your starship prompt instantly
ftl-transient on     # optional: enable transient prompt
```

### Starship configs

The starship theme takes an optional config argument:

```zsh
ftl-prompt starship mytheme
```

The config resolves to the first of these that exists:

1. The argument itself, as a path to a `.toml` file
2. `$ZDOTDIR/themes/mytheme.toml`
3. `${XDG_CONFIG_HOME:-$HOME/.config}/starship/mytheme.toml`

### Alternative for really slow themes

By default the theme loads first and its own prompt is drawn, so what you see
is your real prompt. That's normally what you want and costs a few milliseconds,
which is the right thing for most themes. For a very slow theme however, `-p`
allows you to draw an approximation immediately and loads the theme behind it:

```zsh
ftl-prompt -p '%~ %# ' starship
```

For best results, make the approximation resemble your real prompt.

### Cursor style

A cursor style set by a plugin or editor config only takes effect once it
loads. To apply it up front, set the style before calling `ftl-prompt`:

```zsh
zstyle ':ftl-prompt:' cursor bar
```

Styles are `block`, `underline`, or `bar`, with an optional `blinking-`
prefix, or a raw [DECSCUSR][decscusr] number 0-6.

This covers the gap until your own config loads. It doesn't replace a plugin
that manages cursor shape, like one that changes the cursor per vi mode.

### The zsh prompt system

Themes are ordinary [promptinit][promptinit] themes, loaded from a
`prompt_<name>_setup` file on `fpath`. `ftl-prompt` runs that setup function,
applies the `prompt_opts` it asks for and records `prompt_theme`, which is the
part of the prompt system that matters for setting one theme once.

It does not run `promptinit`, which globs every `fpath` entry for every theme on
the system to build a list only `prompt -l` and `prompt -p` read. Nor does it
tear down a theme that was already set: this runs at the top of your `.zshrc`,
where there is never one to tear down.

If you want `prompt -l`, `prompt -p` or `prompt -r`, or you're switching themes
in a running shell, run `promptinit` yourself. After your prompt is set it costs
nothing, because the prompt is already on screen:

```zsh
ftl-prompt starship
autoload -Uz promptinit && promptinit
```

### Cache

Every question this asks starship is a process spawn, and those spawns are most
of what it costs at startup. The answers are cached under
`${XDG_CACHE_HOME:-~/.cache}/starship-ftl`, keyed on the size and modification
time of the starship binary and your config, so editing `starship.toml`
invalidates the cache on your next shell.

Two edits slip past that key: a config restored from a backup or copied with
`cp -p`, which keeps its old timestamp, and one landing in the same timestamp
tick as the previous edit. If your prompt ever disagrees with your config, rule
that out first:

```zsh
rm -rf ${XDG_CACHE_HOME:-~/.cache}/starship-ftl
```

To ask starship every time instead, before calling `ftl-prompt`:

```zsh
zstyle ':starship-ftl:' cache no
```

## Transient prompt

Replace the prompt on a finished command with a short one, so scrollback reads
as a list of commands instead of a wall of prompts. Opt in, off by default.

Add a profile to your `starship.toml`:

```toml
[profiles]
transient = "[❯](bold green) "
```

Then, once your prompt is set up:

```zsh
ftl-transient on
```

`ftl-transient off` turns it back off. The profile name defaults to `transient`;
pass another to use it instead:

```zsh
ftl-transient on my-short-prompt
```

Only the left prompt is touched, so a finished command keeps whatever its right
prompt showed. To drop that too, use zsh's own option:

```zsh
setopt transient_rprompt
```

## Related projects

- [starship][starship]: the minimal, blazing-fast, customizable prompt
- [instant-zsh][instant-zsh]: romkatv's proof of concept
- [powerlevel10k][p10k]: P10k's famously fast instant prompt

## License

[MIT](LICENSE)

[starship]: https://starship.rs
[romkatv]: https://github.com/romkatv
[instant-zsh]: https://gist.github.com/romkatv/8b318a610dc302bdbe1487bb1847ad99
[p10k]: https://github.com/romkatv/powerlevel10k
[antidote]: https://antidote.sh
[decscusr]: https://vt100.net/docs/vt510-rm/DECSCUSR.html
[promptinit]: https://zsh.sourceforge.io/Doc/Release/User-Contributions.html#Prompt-Themes
