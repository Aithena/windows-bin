#!/usr/bin/env bash
# 用法:
#   tag              显示各格式当前最高版本
#   tag next         在 latest 上补丁号 +1 并推送
#   tag next dev     在指定渠道上补丁号 +1 并推送
#   tag 1.11.11      git tag 1.11.11 && git push --tags && date

set -eu

if [ -t 1 ]; then
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'
  C_GREEN_BOLD=$'\033[1;32m'
  C_CYAN=$'\033[36m'
  C_CYAN_BOLD=$'\033[1;36m'
  C_GRAY=$'\033[90m'   # gray (37 在深色终端里和默认白字几乎一样)
  C_RESET=$'\033[0m'
else
  C_DIM="" C_BOLD="" C_GREEN="" C_GREEN_BOLD="" C_CYAN="" C_CYAN_BOLD="" C_GRAY="" C_RESET=""
fi

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

primary_remote() {
  if git remote | grep -qx origin; then
    echo origin
    return
  fi
  git remote | head -n1
}

# 按「前缀 + 后缀」分成不同格式，结果写入 _family
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
    _family="${prefix}*${rest:${#BASH_REMATCH[0]}}"
  else
    _family="$tag"
  fi
}

# * -> latest, *-dev -> dev, v* -> v, v*-dev -> v-dev
# 结果写入 _channel
channel_of() {
  local label="${1//\*/}"
  label="${label#-}"
  label="${label%-}"
  if [ -z "$label" ]; then
    _channel=latest
  else
    _channel="$label"
  fi
}

each_tag_desc() {
  git for-each-ref --sort=-version:refname --format='%(refname:short)' refs/tags
}

show_max_tags() {
  need_git

  local tag found=0
  unset seen_families 2>/dev/null || true
  declare -A seen_families=()
  while IFS= read -r tag; do
    [ -z "$tag" ] && continue
    found=1
    family_of "$tag"
    if [ -z "${seen_families[$_family]+x}" ]; then
      seen_families[$_family]=1
      channel_of "$_family"
      if [ "$_channel" = "latest" ]; then
        printf '  %s%-8s%s %s%s%s\n' "$C_GREEN" "$_channel" "$C_RESET" "$C_GREEN_BOLD" "$tag" "$C_RESET"
      else
        printf '  %s%-8s%s %s%s%s\n' "$C_DIM" "$_channel" "$C_RESET" "$C_BOLD" "$tag" "$C_RESET"
      fi
    fi
  done < <(each_tag_desc)
  if [ "$found" -eq 0 ]; then
    echo "no tags"
  fi
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
  local tag
  while IFS= read -r tag; do
    [ -z "$tag" ] && continue
    family_of "$tag"
    channel_of "$_family"
    if [ "$_channel" = "$want" ]; then
      echo "$tag"
      return 0
    fi
  done < <(each_tag_desc)
  return 1
}

max_remote_tag_for_channel() {
  local want="$1"
  local remote ref tag
  remote=$(primary_remote)
  [ -n "$remote" ] || return 1
  while IFS=$'\t' read -r _ ref; do
    [ -z "$ref" ] && continue
    tag="${ref#refs/tags/}"
    family_of "$tag"
    channel_of "$_family"
    if [ "$_channel" = "$want" ]; then
      echo "$tag"
      return 0
    fi
  done < <(git ls-remote --refs --tags --sort=-version:refname "$remote" 2>/dev/null || true)
  return 1
}

remote_has_tag() {
  local version="$1"
  local remote
  remote=$(primary_remote)
  [ -n "$remote" ] || return 1
  [ -n "$(git ls-remote --refs --tags "$remote" "refs/tags/$version" 2>/dev/null || true)" ]
}

print_push_line() {
  local line="$1" name
  line="${line%$'\r'}"
  if [[ "$line" =~ \[new\ tag\][[:space:]]+([^[:space:]]+) ]]; then
    name="${BASH_REMATCH[1]}"
    printf '%s%s%s    %s✓%s\n' "$C_CYAN_BOLD" "$name" "$C_RESET" "$C_CYAN" "$C_RESET"
  else
    printf '%s\n' "$line"
  fi
}

create_and_push() {
  local version="$1"
  local remote
  need_git

  if git rev-parse -q --verify "refs/tags/$version" >/dev/null; then
    die "tag $version 已存在"
  fi
  if remote_has_tag "$version"; then
    die "远程已有 tag $version"
  fi

  remote=$(primary_remote)
  [ -n "$remote" ] || die "没有 git remote"

  echo "git tag $version"
  git tag "$version"
  echo "git push $remote $version"
  git push "$remote" "refs/tags/$version" 2>&1 | while IFS= read -r line || [ -n "$line" ]; do
    print_push_line "$line"
  done
  [ "${PIPESTATUS[0]}" -eq 0 ]
  printf '%s' "$C_GRAY"
  date
  printf '%s' "$C_RESET"
}

higher_tag() {
  printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1
}

do_next() {
  local channel="${1:-latest}"
  local current next local_cur="" remote_cur=""
  need_git

  local_cur=$(max_tag_for_channel "$channel" || true)
  remote_cur=$(max_remote_tag_for_channel "$channel" || true)
  if [ -n "$local_cur" ] && [ -n "$remote_cur" ]; then
    current=$(higher_tag "$local_cur" "$remote_cur")
  elif [ -n "$local_cur" ]; then
    current="$local_cur"
  elif [ -n "$remote_cur" ]; then
    current="$remote_cur"
  else
    die "没有 $channel 渠道的 tag"
  fi

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
    create_and_push "$1"
    ;;
esac
