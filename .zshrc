# ==========================================================
# FAST CLEAN ZSH CONFIG — FEDORA POWER USER SETUP
# ==========================================================

# ---------- Powerlevel10k Instant Prompt ----------
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# ==========================================================
# BASIC SHELL OPTIONS
# ==========================================================
setopt AUTO_CD
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_SPACE
setopt SHARE_HISTORY
setopt APPEND_HISTORY
setopt INC_APPEND_HISTORY
setopt EXTENDED_HISTORY
setopt CORRECT

# ==========================================================
# PATH (single clean definition)
# ==========================================================
export PATH="$HOME/.local/bin:$HOME/bin:$HOME/.cargo/bin:$HOME/.npm-global/bin:$PATH"

# ==========================================================
# HISTORY
# ==========================================================
HISTFILE="$HOME/.zsh_history"
HISTSIZE=10000
SAVEHIST=10000

# ==========================================================
# OH-MY-ZSH CORE
# ==========================================================
export ZSH="$HOME/.oh-my-zsh"

ZSH_THEME="powerlevel10k/powerlevel10k"

plugins=(
  git
  fzf-tab
  zsh-autosuggestions
  zsh-syntax-highlighting
  you-should-use
)


source $ZSH/oh-my-zsh.sh

# ==========================================================
# COMPLETION SYSTEM
# ==========================================================
autoload -Uz compinit
compinit -d ~/.cache/zcompdump

# ==========================================================
# FZF (if installed)
# ==========================================================
[[ -f /usr/share/fzf/shell/key-bindings.zsh ]] && source /usr/share/fzf/shell/key-bindings.zsh

# ==========================================================
# TOOL INITIALIZATION
# ==========================================================
command -v zoxide >/dev/null && eval "$(zoxide init zsh)"
eval "$(lacy init zsh)"
# ==========================================================
# WAYLAND CLIPBOARD HELPER
# ==========================================================
copy_clipboard() {
    if [[ -n "$WAYLAND_DISPLAY" ]] && command -v wl-copy >/dev/null; then
        wl-copy
    elif command -v xclip >/dev/null; then
        xclip -selection clipboard
    fi
}

# ==========================================================
# USEFUL ALIASES (SAFE + CLEAN)
# ==========================================================

# package management
alias sdi='sudo dnf install'
alias sdu='sudo dnf upgrade'
alias sds='sudo dnf search'
alias cd='y'
# navigation
alias .='cd ..'
alias ..='cd ../..'
alias yt='yt-dlp'
# editors
alias nano='nvim'
alias v='nvim'
export EDITOR="nvim"
export VISUAL="nvim"
# reload shell
alias zs='source ~/.zshrc'
alias zss='exec zsh'
alias zzz='nvim ~/.zshrc'
# better defaults (require tools)
command -v eza >/dev/null && alias ls='eza --icons'
command -v bat >/dev/null && alias cat='bat'
alias fd='fd -HL'
alias find='fd'
alias cp='xcp'

alias ani1='ani-l'
alias ani2='anipy-cli'
alias ani3='viu'

# ==========================================================
# LOAD POWERLEVEL10K CONFIG
# ==========================================================
[[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh
ZSH_AUTOSUGGEST_STRATEGY=(history completion)
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=#7c6f64"
ZSH_AUTOSUGGEST_USE_ASYNC=1



x() {
    local tmp="$(mktemp -t yazi-cwd.XXXXXX)"
    yazi "$@" --cwd-file="$tmp"
    if cwd="$(cat "$tmp")" && [ -n "$cwd" ] && [ "$cwd" != "$PWD" ]; then
        builtin cd "$cwd"
    fi
    rm -f "$tmp"
}


ff() {
  local file
  file=$(fd --type f --hidden --exclude .git \
    | fzf --preview 'bat --style=numbers --color=always {}')
  [[ -n "$file" ]] && $EDITOR "$file"
}




cdd() {
    y "$@" && ls
}

source /home/salazar/.config/broot/launcher/bash/br
export PATH="$HOME/.cargo/bin:$PATH"


if [[ -n "$KITTY_INSTALLATION_DIR" ]]; then
    autoload -Uz -- "$KITTY_INSTALLATION_DIR"/shell-integration/zsh/kitty-integration
    kitty-integration
    unfunction kitty-integration
fi
alias udb="cd ~/udb && source .venv/bin/activate && python udb.py"
