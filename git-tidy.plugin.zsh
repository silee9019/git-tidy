# git-tidy: safely clean up [gone] local branches
# For trunk-based development with squash merge workflow
#
# Usage:
#   git-tidy              dry-run (default)
#   git-tidy --run        actually delete branches
#   git-tidy --days=N     protect branches with commits within N days (default: 7)
#   git-tidy --no-fetch   skip git fetch --prune
#   git-tidy --help       show usage

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
: "${GIT_TIDY_PROTECT_DAYS:=7}"

# ---------------------------------------------------------------------------
# Internal helpers (namespaced with _git_tidy_)
# ---------------------------------------------------------------------------

# Fallback for git_main_branch() when oh-my-zsh git plugin is not loaded
if ! typeset -f git_main_branch > /dev/null 2>&1; then
  function git_main_branch() {
    command git rev-parse --git-dir &>/dev/null || return
    local ref
    for ref in refs/{heads,remotes/{origin,upstream}}/{main,trunk,mainline,default,stable,master}; do
      if command git show-ref -q --verify "$ref"; then
        echo "${ref:t}"
        return 0
      fi
    done
    echo main
    return 1
  }
fi

# Print with color: _git_tidy_print <color> <message>
_git_tidy_print() {
  local color="$1" msg="$2"
  case "$color" in
    red)    print -P "%F{red}${msg}%f" ;;
    green)  print -P "%F{green}${msg}%f" ;;
    yellow) print -P "%F{yellow}${msg}%f" ;;
    cyan)   print -P "%F{cyan}${msg}%f" ;;
    gray)   print -P "%F{242}${msg}%f" ;;
    *)      print "$msg" ;;
  esac
}

# Get branches checked out in worktrees
_git_tidy_worktree_branches() {
  git worktree list --porcelain 2>/dev/null \
    | awk '/^branch refs\/heads\// { sub("^branch refs/heads/", ""); print }'
}

# Calculate days since last commit on a branch
_git_tidy_days_ago() {
  local branch="$1"
  local epoch
  epoch=$(git for-each-ref --format='%(committerdate:unix)' "refs/heads/$branch" 2>/dev/null) || return 1
  local now=$(date +%s)
  echo $(( (now - epoch) / 86400 ))
}

# ---------------------------------------------------------------------------
# Main function
# ---------------------------------------------------------------------------
git-tidy() {
  emulate -L zsh
  setopt pipefail no_unset

  # --- arg parsing ---
  local run=false
  local fetch=true
  local protect_days="$GIT_TIDY_PROTECT_DAYS"

  local arg
  for arg in "$@"; do
    case "$arg" in
      --run)       run=true ;;
      --no-fetch)  fetch=false ;;
      --days=*)    protect_days="${arg#--days=}" ;;
      --help|-h)
        print "git-tidy: [gone] 브랜치 안전 정리 (trunk-based + squash merge)"
        print ""
        print "Usage:"
        print "  git-tidy              dry-run (삭제 대상만 표시)"
        print "  git-tidy --run        실제 삭제 실행"
        print "  git-tidy --days=N     최근 N일 이내 커밋 브랜치 보호 (기본: ${GIT_TIDY_PROTECT_DAYS}일)"
        print "  git-tidy --no-fetch   git fetch --prune 건너뛰기"
        print ""
        print "Aliases:"
        print "  gtidy                 git-tidy"
        print "  gtidy!                git-tidy --run"
        print ""
        print "Environment:"
        print "  GIT_TIDY_PROTECT_DAYS  최근 커밋 보호 기간 (기본: 7)"
        return 0
        ;;
      *)
        _git_tidy_print red "알 수 없는 옵션: $arg"
        print "git-tidy --help 로 사용법을 확인하세요."
        return 1
        ;;
    esac
  done

  # --- git repo check ---
  if ! git rev-parse --git-dir &>/dev/null; then
    _git_tidy_print red "git 저장소가 아닙니다."
    return 1
  fi

  # --- fetch --prune ---
  if $fetch; then
    _git_tidy_print cyan "fetch --prune 실행 중..."
    if ! git fetch --prune origin 2>/dev/null; then
      _git_tidy_print yellow "fetch 실패 (오프라인? remote 없음?) — 계속 진행합니다."
    fi
  fi

  # --- collect info ---
  local current_branch base_branch
  current_branch=$(git branch --show-current 2>/dev/null) || current_branch=""
  base_branch=$(git_main_branch)

  local -a worktree_branches
  worktree_branches=("${(@f)$(_git_tidy_worktree_branches)}")

  # --- collect gone branches ---
  local -a gone_branches
  gone_branches=("${(@f)$(
    git for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads \
      | grep '\[gone\]' \
      | awk '{print $1}'
  )}")

  # filter empty entries
  gone_branches=("${(@)gone_branches:#}")

  if (( ${#gone_branches} == 0 )); then
    _git_tidy_print green "정리할 [gone] 브랜치가 없습니다."
    return 0
  fi

  # --- classify ---
  local -a to_delete=()
  local -a protected=()
  local -a skipped=()

  local cutoff=$(( $(date +%s) - (protect_days * 86400) ))

  local branch
  for branch in "${gone_branches[@]}"; do
    [[ -z "$branch" ]] && continue

    # current branch
    if [[ "$branch" == "$current_branch" ]]; then
      skipped+=("$branch|현재 브랜치")
      continue
    fi

    # base branch
    if [[ "$branch" == "$base_branch" ]]; then
      skipped+=("$branch|기본 브랜치")
      continue
    fi

    # worktree branch
    if (( ${worktree_branches[(Ie)$branch]} )); then
      protected+=("$branch|worktree")
      continue
    fi

    # recent commit guard
    local commit_epoch
    commit_epoch=$(git for-each-ref --format='%(committerdate:unix)' "refs/heads/$branch" 2>/dev/null)
    if [[ -n "$commit_epoch" ]] && (( commit_epoch > cutoff )); then
      local days_ago=$(_git_tidy_days_ago "$branch")
      protected+=("$branch|최근 커밋 ${days_ago}일 전")
      continue
    fi

    to_delete+=("$branch")
  done

  # --- output ---
  print ""
  if $run; then
    _git_tidy_print cyan "git-tidy: 삭제 실행"
  else
    _git_tidy_print cyan "git-tidy: dry-run (삭제하지 않음)"
  fi
  _git_tidy_print gray "  base=$base_branch  protect=${protect_days}일"
  print ""

  # deletable
  if (( ${#to_delete} > 0 )); then
    if $run; then
      _git_tidy_print red "  삭제 (${#to_delete}):"
    else
      _git_tidy_print red "  삭제 대상 (${#to_delete}):"
    fi
    for branch in "${to_delete[@]}"; do
      if $run; then
        if git branch -D -- "$branch" &>/dev/null; then
          _git_tidy_print green "    삭제됨: $branch"
        else
          _git_tidy_print red "    실패: $branch"
        fi
      else
        _git_tidy_print red "    $branch"
      fi
    done
    print ""
  fi

  # protected
  if (( ${#protected} > 0 )); then
    _git_tidy_print yellow "  보호됨 (${#protected}):"
    local entry
    for entry in "${protected[@]}"; do
      local name="${entry%%|*}"
      local reason="${entry#*|}"
      _git_tidy_print yellow "    $name  ($reason)"
    done
    print ""
  fi

  # skipped
  if (( ${#skipped} > 0 )); then
    _git_tidy_print gray "  건너뜀 (${#skipped}):"
    local entry
    for entry in "${skipped[@]}"; do
      local name="${entry%%|*}"
      local reason="${entry#*|}"
      _git_tidy_print gray "    $name  ($reason)"
    done
    print ""
  fi

  # hint
  if ! $run && (( ${#to_delete} > 0 )); then
    _git_tidy_print gray "  → git-tidy --run 으로 실제 삭제를 실행하세요."
  fi
}

# ---------------------------------------------------------------------------
# Aliases
# ---------------------------------------------------------------------------
alias gtidy='git-tidy'
alias 'gtidy!'='git-tidy --run'

# ---------------------------------------------------------------------------
# Completion
# ---------------------------------------------------------------------------
_git-tidy() {
  _arguments \
    '--run[실제 삭제 실행]' \
    '--days=[최근 커밋 보호 기간 (일)]:days:(1 3 7 14 30)' \
    '--no-fetch[fetch --prune 건너뛰기]' \
    '--help[사용법 출력]'
}
compdef _git-tidy git-tidy
