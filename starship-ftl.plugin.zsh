0=${(%):-%N}
typeset -gUa fpath
fpath=(${0:A:h}/completions $fpath)
source ${0:A:h}/ftl-prompt.zsh
source ${0:A:h}/ftl-transient.zsh
