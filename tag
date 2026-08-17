#!/usr/bin/env bash
# 用法:
#   tag              显示各渠道当前最高版本
#   tag next         在 latest 上补丁号 +1 并推送
#   tag next dev     在指定渠道上补丁号 +1 并推送
#   tag 1.1.1        git push && git tag && 跟踪远程打包

set -eu

if [ -t 1 ]; then
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'
  C_GREEN_BOLD=$'\033[1;32m'
  C_CYAN=$'\033[36m'
  C_CYAN_BOLD=$'\033[1;36m'
  C_RED=$'\033[31m'
  C_GRAY=$'\033[90m'   # gray (37 在深色终端里和默认白字几乎一样)
  C_RESET=$'\033[0m'
else
  C_DIM="" C_BOLD="" C_GREEN="" C_GREEN_BOLD="" C_CYAN="" C_CYAN_BOLD="" C_RED="" C_GRAY="" C_RESET=""
fi

die() {
  echo "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
用法:
  tag              显示各渠道当前最高版本
  tag next         在 latest 上补丁号 +1 并推送
  tag next dev     在指定渠道上补丁号 +1 并推送（dev / pre / test）
  tag 1.1.1        打指定版本（1.1.1 / 1.1.1-dev / 1.1.1-pre / 1.1.1-test）
  tag help         显示帮助

环境变量:
  GITLAB_TOKEN     GitLab 私人令牌，推送后跟踪 CI 打包进度
  TAG_WATCH=0      跳过远程打包跟踪
  DOCKER_REGISTRY  镜像仓库主机，默认 docker-registry.kangyishou.com
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

pack_token() {
  local kind="$1"
  case "$kind" in
    gitlab)
      if [ -n "${GITLAB_TOKEN:-}${GITLAB_PRIVATE_TOKEN:-}${PRIVATE_TOKEN:-}" ]; then
        echo "${GITLAB_TOKEN:-${GITLAB_PRIVATE_TOKEN:-$PRIVATE_TOKEN}}"
        return
      fi
      git config --get gitlab.token 2>/dev/null || true
      ;;
    gitee)
      if [ -n "${GITEE_TOKEN:-}${GITEE_ACCESS_TOKEN:-}" ]; then
        echo "${GITEE_TOKEN:-$GITEE_ACCESS_TOKEN}"
        return
      fi
      git config --get gitee.token 2>/dev/null || true
      ;;
    github)
      if [ -n "${GITHUB_TOKEN:-}${GH_TOKEN:-}" ]; then
        echo "${GITHUB_TOKEN:-$GH_TOKEN}"
        return
      fi
      git config --get github.token 2>/dev/null || true
      ;;
  esac
}

parse_remote_repo() {
  local remote url path scheme=https cfg
  remote=$(primary_remote)
  [ -n "$remote" ] || return 1
  url=$(git remote get-url "$remote")
  url="${url%.git}"
  url="${url%/}"
  if [[ "$url" =~ ^git@([^:]+):(.+)$ ]]; then
    _host="${BASH_REMATCH[1]}"
    path="${BASH_REMATCH[2]}"
  elif [[ "$url" =~ ^ssh://([^@]+@)?([^/]+)/(.+)$ ]]; then
    _host="${BASH_REMATCH[2]}"
    path="${BASH_REMATCH[3]}"
  elif [[ "$url" =~ ^https?://([^/]+)/(.+)$ ]]; then
    _host="${BASH_REMATCH[1]}"
    path="${BASH_REMATCH[2]}"
    [[ "$url" == http://* ]] && scheme=http
  else
    return 1
  fi
  _project="$path"
  _base="$scheme://$_host"
  cfg=$(git config --get gitlab.url 2>/dev/null || true)
  [ -n "$cfg" ] && _base="${cfg%/}"
  case "$_host" in
    *gitee.com*) _kind=gitee ;;
    *github.com*) _kind=github ;;
    *) _kind=gitlab ;;
  esac
}

pack_probe() {
  python - "$1" "$2" "$3" "$4" "$5" "$6" <<'PY'
import json, ssl, sys, urllib.error, urllib.parse, urllib.request
from datetime import datetime, timezone

kind, base, project, sha, tag, token = sys.argv[1:7]
INSECURE = ssl._create_unverified_context()

def fetch(url, headers=None, insecure=False):
    req = urllib.request.Request(url, headers=headers or {"User-Agent": "tag-cli"})
    ctx = INSECURE if insecure else None
    try:
        with urllib.request.urlopen(req, timeout=15, context=ctx) as resp:
            return resp.status, json.load(resp)
    except urllib.error.HTTPError as err:
        try:
            data = json.loads(err.read().decode("utf-8", "replace"))
        except Exception:
            data = {}
        return err.code, data
    except Exception:
        return 0, {}

def emit(state, pack=("pending", 0, 0), deploy=("pending", 0, 0)):
    print("%s\t%s\t%s\t%s\t%s\t%s\t%s" % (
        state, pack[0], pack[1], pack[2], deploy[0], deploy[1], deploy[2]
    ))
    sys.exit(0)

def gitee(path):
    url = "https://gitee.com/api/v5" + path
    url += ("&" if "?" in url else "?") + "access_token=" + urllib.parse.quote(token)
    return fetch(url)

def github(path):
    return fetch(
        "https://api.github.com" + path,
        {
            "Authorization": "Bearer " + token,
            "Accept": "application/vnd.github+json",
            "User-Agent": "tag-cli",
        },
    )

def gitlab(path):
    url = base.rstrip("/") + "/api/v4" + path
    return fetch(url, {"PRIVATE-TOKEN": token, "User-Agent": "tag-cli"}, insecure=True)

def job_secs(job):
    d = job.get("duration")
    if d is not None:
        try:
            return max(0, int(float(d)))
        except Exception:
            pass
    started = job.get("started_at")
    if not started:
        return 0
    try:
        if started.endswith("Z"):
            started = started[:-1] + "+00:00"
        t0 = datetime.fromisoformat(started)
        if t0.tzinfo is None:
            t0 = t0.replace(tzinfo=timezone.utc)
        return max(0, int((datetime.now(timezone.utc) - t0).total_seconds()))
    except Exception:
        return 0

def is_deploy_job(job):
    blob = "%s %s" % (job.get("stage") or "", job.get("name") or "")
    low = blob.lower()
    for key in ("deploy", "release", "publish", "install", "rollout", "交付"):
        if key in low:
            return True
    return "部署" in blob

def split_jobs(jobs):
    pack, deploy = [], []
    stages = []
    for job in jobs:
        stage = job.get("stage") or ""
        if stage not in stages:
            stages.append(stage)
        if is_deploy_job(job):
            deploy.append(job)
        else:
            pack.append(job)
    if not deploy and len(stages) >= 2:
        last = stages[-1]
        pack, deploy = [], []
        for job in jobs:
            if (job.get("stage") or "") == last:
                deploy.append(job)
            else:
                pack.append(job)
    elif not deploy and len(jobs) >= 2:
        pack, deploy = jobs[:1], jobs[1:]
    return pack, deploy

def summarize(jobs):
    if not jobs:
        return ("pending", 0, 0)
    total = len(jobs)
    done = failed = running = pending = 0
    secs = 0
    for job in jobs:
        js = (job.get("status") or "").lower()
        secs += job_secs(job)
        if js in ("success", "failed", "canceled", "skipped"):
            done += 1
        if js == "failed":
            failed += 1
        elif js == "running":
            running += 1
        elif js in ("created", "pending", "waiting_for_resource", "preparing", "scheduled", "manual"):
            pending += 1
    pct = int(done * 100 / total) if total else 0
    if failed and not running:
        return ("failure", 100, secs)
    if running:
        return ("running", pct, secs)
    if pending and done < total:
        return ("pending", pct, secs)
    if done == total:
        return ("failure" if failed else "success", 100, secs)
    return ("pending", pct, secs)

pending = running = success = failure = False
details = []
files = []
saw = False
pct = 0
pack_sum = ("pending", 0, 0)
deploy_sum = ("pending", 0, 0)

if kind == "gitlab":
    pid = urllib.parse.quote(project, safe="")
    q = urllib.parse.urlencode({"ref": tag, "sha": sha, "per_page": 5})
    code, data = gitlab("/projects/%s/pipelines?%s" % (pid, q))
    if code in (401, 403):
        emit("auth")
    if code != 200 or not data:
        q = urllib.parse.urlencode({"ref": tag, "per_page": 5})
        code, data = gitlab("/projects/%s/pipelines?%s" % (pid, q))
        if code in (401, 403):
            emit("auth")
    if code == 200 and data:
        pipe = data[0]
        saw = True
        st = (pipe.get("status") or "").lower()
        code, jobs = gitlab("/projects/%s/pipelines/%s/jobs?per_page=100" % (pid, pipe["id"]))
        if code != 200 or not isinstance(jobs, list):
            jobs = []
        jobs.sort(key=lambda j: j.get("id") or 0)
        pack_jobs, deploy_jobs = split_jobs(jobs)
        pack_sum = summarize(pack_jobs)
        deploy_sum = summarize(deploy_jobs)
        if st in ("created", "waiting_for_resource", "preparing", "pending", "scheduled"):
            pending = True
        elif st == "running":
            running = True
        elif st == "success":
            success = True
        elif st in ("failed", "canceled"):
            failure = True
        if pack_sum[0] == "failure" or deploy_sum[0] == "failure":
            failure = True
        if pack_sum[0] == "running" or deploy_sum[0] == "running":
            running = True
        if pack_sum[0] == "pending" or deploy_sum[0] == "pending":
            pending = True
        if pack_sum[0] == "success":
            success = True
        code, rel = gitlab("/projects/%s/releases/%s" % (pid, urllib.parse.quote(tag, safe="")))
        if code == 200 and isinstance(rel, dict):
            for link in (rel.get("assets") or {}).get("links") or []:
                name = link.get("name") or link.get("url")
                if name:
                    files.append(name)
        code, pkgs = gitlab("/projects/%s/packages?per_page=10&%s" % (
            pid, urllib.parse.urlencode({"package_version": tag})
        ))
        if code == 200 and isinstance(pkgs, list):
            for pkg in pkgs:
                name = pkg.get("name") or ""
                ver = pkg.get("version") or ""
                label = "%s%s" % (name, " " + ver if ver else "")
                if label.strip():
                    files.append(label.strip())
    else:
        emit("none")

elif kind == "gitee":
    owner, repo = project.split("/", 1)
    code, data = gitee("/repos/%s/%s/commits/%s/check-runs" % (owner, repo, sha))
    if code in (401, 403):
        emit("auth")
    if code == 200:
        for item in data.get("check_runs") or []:
            saw = True
            status = (item.get("status") or "").lower()
            conclusion = (item.get("conclusion") or "").lower()
            name = item.get("name") or "检查"
            if status in ("queued", "waiting"):
                pending = True
                details.append(name)
            elif status == "in_progress":
                running = True
                details.append(name)
            elif conclusion in ("failure", "timed_out", "cancelled", "action_required"):
                failure = True
                details.append(name)
            elif conclusion in ("success", "neutral", "skipped"):
                success = True
            else:
                pending = True
                details.append(name)
    code, data = gitee("/repos/%s/%s/commits/%s/statuses" % (owner, repo, sha))
    if code == 200:
        items = data if isinstance(data, list) else data.get("statuses") or []
        for item in items:
            saw = True
            state = (item.get("state") or "").lower()
            name = item.get("context") or item.get("description") or "状态"
            if state == "pending":
                pending = True
                details.append(name)
            elif state in ("error", "failure"):
                failure = True
                details.append(name)
            elif state == "success":
                success = True
    code, rel = gitee("/repos/%s/%s/releases/tags/%s" % (
        owner, repo, urllib.parse.quote(tag, safe="")
    ))
    if code == 200 and isinstance(rel, dict) and rel.get("id"):
        saw = True
        pending = True
        rid = rel["id"]
        code, assets = gitee("/repos/%s/%s/releases/%d/attach_files" % (owner, repo, rid))
        if code == 200:
            items = assets if isinstance(assets, list) else assets.get("attach_files") or assets.get("assets") or []
            for item in items:
                name = item.get("name") or item.get("file_name")
                if name:
                    files.append(name)
            if files:
                success = True
                pending = False

elif kind == "github":
    owner, repo = project.split("/", 1)
    code, data = github("/repos/%s/%s/commits/%s/check-runs" % (owner, repo, sha))
    if code in (401, 403):
        emit("auth")
    if code == 200:
        for item in data.get("check_runs") or []:
            saw = True
            status = (item.get("status") or "").lower()
            conclusion = (item.get("conclusion") or "").lower()
            name = item.get("name") or "检查"
            if status in ("queued", "waiting", "pending", "requested"):
                pending = True
                details.append(name)
            elif status == "in_progress":
                running = True
                details.append(name)
            elif conclusion in ("failure", "timed_out", "cancelled", "action_required"):
                failure = True
                details.append(name)
            elif conclusion in ("success", "neutral", "skipped"):
                success = True
    code, data = github("/repos/%s/%s/commits/%s/status" % (owner, repo, sha))
    if code == 200:
        state = (data.get("state") or "").lower()
        if state == "pending":
            saw = True
            pending = True
        elif state in ("error", "failure"):
            saw = True
            failure = True
        elif state == "success":
            saw = True
            success = True
    code, data = github("/repos/%s/%s/actions/runs?per_page=8" % (owner, repo))
    if code == 200:
        for item in data.get("workflow_runs") or []:
            if item.get("head_sha") != sha and item.get("head_branch") != tag:
                continue
            saw = True
            status = (item.get("status") or "").lower()
            conclusion = (item.get("conclusion") or "").lower()
            name = item.get("name") or "工作流"
            if status in ("queued", "waiting", "pending", "requested"):
                pending = True
                details.append(name)
            elif status == "in_progress":
                running = True
                details.append(name)
            elif conclusion in ("failure", "timed_out", "cancelled"):
                failure = True
                details.append(name)
            elif conclusion == "success":
                success = True
    code, rel = github("/repos/%s/%s/releases/tags/%s" % (
        owner, repo, urllib.parse.quote(tag, safe="")
    ))
    if code == 200 and isinstance(rel, dict):
        for item in rel.get("assets") or []:
            name = item.get("name")
            if name:
                files.append(name)
        if files:
            saw = True
            success = True

if not saw:
    emit("none")
elif failure and not running and not pending:
    overall = "failure"
elif running:
    overall = "running"
elif pending:
    overall = "pending"
elif success:
    overall = "success"
else:
    overall = "none"

if kind != "gitlab":
    pack_sum = (overall if overall != "none" else "pending", 100 if overall in ("success", "failure") else pct, 0)
    deploy_sum = ("pending", 0, 0)
emit(overall, pack_sum, deploy_sum)
PY
}

fill_bar() {
  local state="$1" percent="${2:-0}" bounce="${3:-0}" width=12 i pos fill
  _bar=""
  case "$percent" in
    ''|*[!0-9]*) percent=0 ;;
  esac
  case "$bounce" in
    ''|*[!0-9]*) bounce=0 ;;
  esac
  case "$state" in
    pending)
      pos=$((bounce % (width - 3)))
      for ((i = 0; i < width; i++)); do
        if [ "$i" -ge "$pos" ] && [ "$i" -lt $((pos + 4)) ]; then
          _bar+="#"
        else
          _bar+="-"
        fi
      done
      ;;
    running)
      fill=$percent
      case "$fill" in
        ''|*[!0-9]*) fill=0 ;;
      esac
      [ "$fill" -gt $((width - 2)) ] && fill=$((width - 2))
      for ((i = 0; i < width; i++)); do
        if [ "$i" -lt "$fill" ]; then
          _bar+="#"
        else
          _bar+="-"
        fi
      done
      ;;
    success|failure)
      for ((i = 0; i < width; i++)); do
        _bar+="#"
      done
      ;;
    *)
      for ((i = 0; i < width; i++)); do
        _bar+="-"
      done
      ;;
  esac
}

print_phase_line() {
  local label="$1" state="$2" percent="$3" secs="$4" bounce="$5" color
  case "$state" in
    pending) color="$C_GRAY" ;;
    running) color="$C_CYAN" ;;
    success) color="$C_GREEN" ;;
    failure) color="$C_RED" ;;
    *) color="$C_GRAY" ;;
  esac
  case "$secs" in
    ''|*[!0-9]*) secs=0 ;;
  esac
  fill_bar "$state" "$percent" "$bounce"
  printf '%s%s  [%s] %ss%s' "$color" "$label" "$_bar" "$secs" "$C_RESET"
}

draw_two_phases() {
  local pack_state="$1" pack_pct="$2" pack_sec="$3"
  local deploy_state="$4" deploy_pct="$5" deploy_sec="$6"
  local bounce="${7:-0}"
  if [ -t 1 ] && [ "${_pack_ui_drawn:-0}" = 1 ]; then
    printf '\033[2A\r\033[K'
    print_phase_line "打包" "$pack_state" "$pack_pct" "$pack_sec" "$bounce"
    printf '\n\r\033[K'
    print_phase_line "部署" "$deploy_state" "$deploy_pct" "$deploy_sec" "$bounce"
    printf '\n'
  else
    print_phase_line "打包" "$pack_state" "$pack_pct" "$pack_sec" "$bounce"
    printf '\n'
    print_phase_line "部署" "$deploy_state" "$deploy_pct" "$deploy_sec" "$bounce"
    printf '\n'
    _pack_ui_drawn=1
  fi
}

watch_remote_pack() {
  local version="$1"
  local token sha state="" elapsed=0 last="" now
  local p_st=pending p_pct=0 p_sec=0 d_st=pending d_pct=0 d_sec=0
  local p_cells=0 d_cells=0 p_draw
  local bar_width=12 hold=2 cap phase1_cells pack_elapsed
  local t0=0 pack_t0=0 deploy_t0=0 last_probe=0
  local detect_limit timeout_limit probe_file done_file
  _pack_ui_drawn=0
  _tag_watch_pid=""
  _tag_watch_file=""

  [ "${TAG_WATCH:-1}" = "0" ] && return 0
  command -v python >/dev/null 2>&1 || return 0
  parse_remote_repo || return 0
  token=$(pack_token "$_kind")
  if [ -z "$token" ]; then
    printf '%s未跟踪远程打包（设置 GITLAB_TOKEN 后可显示进度）%s\n' "$C_GRAY" "$C_RESET"
    return 0
  fi

  sha=$(git rev-parse "${version}^{commit}" 2>/dev/null) || sha=$(git rev-parse "$version")
  detect_limit="${TAG_WATCH_DETECT:-20}"
  timeout_limit="${TAG_WATCH_TIMEOUT:-600}"
  t0=$(date +%s)
  pack_t0=$t0
  cap=$((bar_width - hold))
  phase1_cells=$(( (bar_width * 30 + 50) / 100 ))
  probe_file=$(mktemp "${TMPDIR:-/tmp}/tag-watch.XXXXXX")
  done_file="${probe_file}.done"
  _tag_watch_file=$probe_file

  cleanup_watch() {
    if [ -n "${_tag_watch_pid:-}" ]; then
      kill "$_tag_watch_pid" 2>/dev/null || true
      _tag_watch_pid=""
    fi
    rm -f "${_tag_watch_file:-}" "${_tag_watch_file:-}.done" "${_tag_watch_file:-}.part" "${_tag_watch_file:-}.busy"
    _tag_watch_file=""
  }
  trap cleanup_watch EXIT

  while [ "$elapsed" -le "$timeout_limit" ]; do
    now=$(date +%s)
    elapsed=$((now - t0))

    if [ -f "$done_file" ]; then
      last=$(cat "$done_file" 2>/dev/null || true)
      rm -f "$done_file"
      IFS=$'\t' read -r state p_st p_pct p_sec d_st d_pct d_sec <<<"$last"
      [ -z "$state" ] && state=none
    fi

    if [ ! -f "${probe_file}.busy" ]; then
      if [ "$last_probe" -eq 0 ] || [ $((now - last_probe)) -ge 2 ]; then
        : >"${probe_file}.busy"
        (
          set +e
          pack_probe "$_kind" "$_base" "$_project" "$sha" "$version" "$token" >"${probe_file}.part" 2>/dev/null
          mv "${probe_file}.part" "$done_file" 2>/dev/null
          rm -f "${probe_file}.busy"
        ) &
        _tag_watch_pid=$!
        last_probe=$now
      fi
    fi

    pack_elapsed=$((now - pack_t0))
    if [ "$pack_elapsed" -le 10 ]; then
      p_cells=$((phase1_cells * pack_elapsed / 10))
    else
      p_cells=$((phase1_cells + (pack_elapsed - 10) / 10))
    fi
    [ "$p_cells" -gt "$cap" ] && p_cells=$cap
    if [ "$p_st" = "success" ] || [ "$p_st" = "failure" ]; then
      p_cells=$bar_width
    fi

    if [ "$d_st" = "running" ] || [ "$d_st" = "success" ] || [ "$d_st" = "failure" ]; then
      if [ "$deploy_t0" -eq 0 ]; then
        deploy_t0=$now
      fi
      d_cells=$(( (now - deploy_t0) * 2 ))
      [ "$d_cells" -gt "$cap" ] && d_cells=$cap
      if [ "$d_st" = "success" ] || [ "$d_st" = "failure" ]; then
        d_cells=$bar_width
      fi
    else
      d_cells=0
    fi

    case "$state" in
      auth)
        trap - EXIT
        cleanup_watch
        printf '%s远程打包跟踪失败：令牌无效或没有权限%s\n' "$C_GRAY" "$C_RESET"
        return 0
        ;;
      none|"")
        if [ "$elapsed" -ge "$detect_limit" ]; then
          if [ -t 1 ] && [ "${_pack_ui_drawn:-0}" = 1 ]; then
            printf '\033[2A\r\033[K\n\r\033[K\033[1A'
          elif [ -t 1 ]; then
            printf '\r\033[K'
          fi
          trap - EXIT
          cleanup_watch
          printf '%s未检测到远程打包%s\n' "$C_GRAY" "$C_RESET"
          return 0
        fi
        draw_two_phases running "$p_cells" "$elapsed" pending 0 0 "$elapsed"
        ;;
      pending|running|success|failure)
        p_draw=${p_st:-pending}
        if [ "$p_draw" != "success" ] && [ "$p_draw" != "failure" ]; then
          p_draw=running
        fi
        draw_two_phases "$p_draw" "$p_cells" "${p_sec:-0}" \
          "${d_st:-pending}" "$d_cells" "${d_sec:-0}" "$elapsed"
        if [ "$state" = "success" ]; then
          trap - EXIT
          cleanup_watch
          print_image_line "$version"
          return 0
        fi
        if [ "$state" = "failure" ]; then
          trap - EXIT
          cleanup_watch
          die "${C_RED}远程打包失败${C_RESET}"
        fi
        ;;
    esac

    sleep 1
  done

  if [ -t 1 ] && [ "${_pack_ui_drawn:-0}" = 1 ]; then
    printf '\033[2A\r\033[K\n\r\033[K\033[1A'
  elif [ -t 1 ]; then
    printf '\r\033[K'
  fi
  trap - EXIT
  cleanup_watch
  printf '%s远程打包超时（%ss）%s\n' "$C_GRAY" "$timeout_limit" "$C_RESET"
}

print_image_line() {
  local version="$1" registry project image
  [ -n "${_project:-}" ] || return 0
  registry="${DOCKER_REGISTRY:-}"
  if [ -z "$registry" ]; then
    registry=$(git config --get docker.registry 2>/dev/null || true)
  fi
  [ -z "$registry" ] && registry=docker-registry.kangyishou.com
  project="${_project#/}"
  project="${project%/}"
  image="$registry/$project:$version"
  if [ -c /dev/clipboard ]; then
    printf '%s' "$image" > /dev/clipboard
  elif command -v clip.exe >/dev/null 2>&1; then
    printf '%s' "$image" | clip.exe
  fi
  printf '%s镜像  %s%s\n' "$C_GREEN" "$image" "$C_RESET"
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
  local remote branch
  need_git

  if git rev-parse -q --verify "refs/tags/$version" >/dev/null; then
    die "tag $version 已存在"
  fi
  if remote_has_tag "$version"; then
    die "远程已有 tag $version"
  fi

  remote=$(primary_remote)
  [ -n "$remote" ] || die "没有 git remote"
  branch=$(git symbolic-ref --short HEAD 2>/dev/null) || die "当前不在分支上，无法推送本地提交"

  echo "git push $remote $branch"
  git push "$remote" "$branch"
  echo "git tag $version"
  git tag "$version"
  echo "git push $remote $version"
  git push "$remote" "refs/tags/$version" 2>&1 | while IFS= read -r line || [ -n "$line" ]; do
    print_push_line "$line"
  done
  [ "${PIPESTATUS[0]}" -eq 0 ]
  watch_remote_pack "$version"
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
    if [ "$#" -eq 1 ]; then
      do_next latest
    elif [ "$#" -eq 2 ]; then
      case "$2" in
        dev|pre|test) do_next "$2" ;;
        *) die "未知渠道: $2
用法: tag next [dev|pre|test]" ;;
      esac
    else
      die "用法: tag next [dev|pre|test]"
    fi
    ;;
  help|-h|--help)
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
    if [[ "$1" =~ ^[0-9] ]]; then
      if [[ ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(dev|pre|test))?$ ]]; then
        die "版本号必须是 1.1.1 或 1.1.1-dev|pre|test"
      fi
      create_and_push "$1"
    else
      die "未知命令: $1
用法: tag next [dev|pre|test]
     tag 1.1.1[-dev|-pre|-test]"
    fi
    ;;
esac
