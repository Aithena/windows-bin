#!/usr/bin/env bash
# 用法:
#   tag              显示各格式当前最高版本
#   tag next         在 latest 上补丁号 +1 并推送
#   tag next dev     在指定渠道上补丁号 +1 并推送
#   tag 1.11.11      git tag 1.11.11 && git push --tags && date

set -eu

die() {
  echo "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
用法:
  tag              显示各格式当前最高版本
  tag next         在 latest 上补丁号 +1 并推送
  tag next dev     在指定渠道上补丁号 +1 并推送
  tag 1.11.11      git tag 1.11.11 && git push --tags && date
  tag -h           显示帮助
EOF
}

need_git() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "当前目录不是 git 仓库"
}

# 按「前缀 + 后缀」分成不同格式，例如:
#   1.1.2        -> *
#   1.1.1-dev    -> *-dev
#   v2.0.0       -> v*
#   v2.0.0-dev   -> v*-dev
family_of() {
  local tag="$1"
  local prefix="" rest="$tag"

  if [[ "$tag" =~ ^([A-Za-z]+[-_]*)(.*)$ ]]; then
    prefix="${BASH_REMATCH[1]}"
    rest="${BASH_REMATCH[2]}"
  fi

  if [[ "$rest" =~ ^[0-9]+(\.[0-9]+)* ]]; then
    echo "${prefix}*${rest:${#BASH_REMATCH[0]}}"
  else
    echo "$tag"
  fi
}

# * -> latest, *-dev -> dev, v* -> v, v*-dev -> v-dev
channel_of() {
  local label="${1//\*/}"
  label="${label#-}"
  label="${label%-}"
  if [ -z "$label" ]; then
    echo latest
  else
    echo "$label"
  fi
}

show_max_tags() {
  need_git

  local tags tag family channel dim bold reset
  tags=$(git tag --list --sort=-v:refname || true)
  if [ -z "$tags" ]; then
    echo "no tags"
    return
  fi

  if [ -t 1 ]; then
    dim=$'\033[2m'
    bold=$'\033[1m'
    reset=$'\033[0m'
  else
    dim="" bold="" reset=""
  fi

  unset seen_families 2>/dev/null || true
  declare -A seen_families=()
  while IFS= read -r tag; do
    [ -z "$tag" ] && continue
    family=$(family_of "$tag")
    if [ -z "${seen_families[$family]+x}" ]; then
      seen_families[$family]=1
      channel=$(channel_of "$family")
      printf '  %s%-8s%s %s%s%s\n' "$dim" "$channel" "$reset" "$bold" "$tag" "$reset"
    fi
  done <<EOF
$tags
EOF
}

fetch_tags() {
  git fetch --tags --quiet 2>/dev/null || true
}

# 1.1.2 -> 1.1.3, 1.1.1-dev -> 1.1.2-dev, v1.2.9 -> v1.2.10
bump_patch() {
  local tag="$1"
  if [[ "$tag" =~ ^(.*[^0-9])([0-9]+)(.*)$ ]]; then
    echo "${BASH_REMATCH[1]}$((10#${BASH_REMATCH[2]} + 1))${BASH_REMATCH[3]}"
  elif [[ "$tag" =~ ^([0-9]+)$ ]]; then
    echo $((10#${BASH_REMATCH[1]} + 1))
  else
    die "无法从 $tag 计算下一个版本"
  fi
}

max_tag_for_channel() {
  local want="$1"
  local tag family channel
  local tags
  tags=$(git tag --list --sort=-v:refname || true)
  while IFS= read -r tag; do
    [ -z "$tag" ] && continue
    family=$(family_of "$tag")
    channel=$(channel_of "$family")
    if [ "$channel" = "$want" ]; then
      echo "$tag"
      return 0
    fi
  done <<EOF
$tags
EOF
  return 1
}

create_and_push() {
  local version="$1"
  need_git

  if git rev-parse -q --verify "refs/tags/$version" >/dev/null; then
    die "tag $version 已存在"
  fi

  echo "git tag $version"
  git tag "$version"
  echo "git push --tags"
  git push --tags
  date
}

do_next() {
  local channel="${1:-latest}"
  local current next
  need_git
  fetch_tags

  current=$(max_tag_for_channel "$channel") || die "没有 $channel 渠道的 tag"
  next=$(bump_patch "$current")
  echo "$current -> $next"
  create_and_push "$next"
}

case "${1:-}" in
  ""|-l)
    show_max_tags
    ;;
  next)
    if [ "$#" -gt 2 ]; then
      die "用法: tag next [渠道]"
    fi
    do_next "${2:-latest}"
    ;;
  -h|--help)
    usage
    ;;
  -*)
    die "未知参数: $1
$(usage)"
    ;;
  *)
    if [ "$#" -ne 1 ]; then
      die "一次只接收一个版本号
$(usage)"
    fi
    fetch_tags
    create_and_push "$1"
    ;;
esac
