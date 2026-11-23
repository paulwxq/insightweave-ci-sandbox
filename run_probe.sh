#!/usr/bin/env bash
# run_probe.sh —— doc 15.1 实验驱动与取证脚本（非生产）
# 用法：run_probe.sh <owner/repo> <c1|c2|c3|c4|c5|c6> [batch]
# 说明：job 名即 job id（verify/release/maintenance/finalize）；步骤名只出现在日志。
# 产物：docs/reviews/doc15.1-evidence/<batch>/<case>/ 下分阶段 run/jobs JSON、关键 job 日志、timeline.txt、verdict.txt
set -euo pipefail

REPO=${1:?用法：run_probe.sh <owner/repo> <case> [batch]}
CASE=${2:?case: c1|c2|c3|c4|c5|c6}
BATCH=${3:-$(date -u +%m%d%H%M)}
GROUP="insightweave-concurrency-probe-$BATCH-$CASE"
WFR=concurrency-probe.yml        # release-sim
WFM=concurrency-probe-maint.yml  # maint-sim
EVROOT="$(cd "$(dirname "$0")/.." && pwd)/doc15.1-evidence/$BATCH/$CASE"
REF=${REF:-main}
mkdir -p "$EVROOT"
TL="$EVROOT/timeline.txt"
note() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$TL"; }

disp() { # disp <workflow> <role-tag> <mode> <hold> [finalize_hold]
  local wf=$1 tag="$BATCH-$CASE-$2" mode=$3 hold=${4:-120} fh=${5:-0}
  gh workflow run "$wf" -R "$REPO" --ref "$REF" \
    -f group="$GROUP" -f tag="$tag" -f mode="$mode" \
    -f hold_seconds="$hold" -f finalize_hold_seconds="$fh" >/dev/null
  note "dispatched $wf role=$2 mode=$3 hold=$hold finalize_hold=$fh group=$GROUP"
}
runid() { # runid <workflow> <role-tag>
  local wf=$1 want="probe-$BATCH-$CASE-$2" i id
  for i in $(seq 1 20); do
    id=$(gh run list -R "$REPO" --workflow "$wf" --limit 25 --json databaseId,displayTitle \
      --jq ".[] | select(.displayTitle==\"$want\") | .databaseId" | head -1 || true)
    [ -n "$id" ] && { echo "$id"; return 0; }
    sleep 2
  done
  echo "runid: 未找到 $want" >&2; return 1
}
jfield() { # jfield <run_id> <job-name-regex> <field>
  gh api "repos/$REPO/actions/runs/$1/jobs?per_page=100" \
    --jq ".jobs[] | select(.name | test(\"$2\")) | .[\"$3\"]" | head -1
}
jid() { jfield "$1" "$2" id; }
snap() { # snap <run_id> <label>
  local id=$1 label=$2 st
  gh api "repos/$REPO/actions/runs/$id" >"$EVROOT/${label}-run.json"
  gh api "repos/$REPO/actions/runs/$id/jobs?per_page=100" >"$EVROOT/${label}-jobs.json"
  st=$(gh api "repos/$REPO/actions/runs/$id" --jq '.status+"/"+(.conclusion//"-")')
  note "snapshot $label run=$id status=$st"
}
slog() { # slog <run_id> <job-name-regex> <label>
  local id; id=$(jid "$1" "$2") || true
  if [ -n "${id:-}" ]; then
    gh run view -R "$REPO" --job "$id" --log >"$EVROOT/$3.log" 2>&1 || true
    note "log saved $3 (job=$id)"
  else
    note "log MISSING $3 (job not found by regex $2)"
  fi
}
wait_run() { # wait_run <run_id> <maxsec>
  local i; for i in $(seq 1 $(( ($2 + 4) / 5 ))); do
    [ "$(gh api "repos/$REPO/actions/runs/$1" --jq .status)" = completed ] && return 0
    sleep 5
  done; return 1
}
wait_job() { # wait_job <run_id> <job-regex> <status> <maxsec>
  local i; for i in $(seq 1 $(( ($4 + 4) / 5 ))); do
    [ "$(jfield "$1" "$2" status)" = "$3" ] && return 0
    sleep 5
  done; return 1
}
cond() { jfield "$1" "$2" conclusion; }
verdict_out() { printf '%s\n' "$*" | tee -a "$TL" >"$EVROOT/verdict.txt"; }

AB() { # AB <holdA> —— 前置：A 执行中、B verify 成功且 release 排队等待同组；成功后置全局 AB_A/AB_B
  local i ok="" vs="" bs=""
  disp "$WFR" A ok "${1:-120}" 0; AB_A=$(runid "$WFR" A)
  if ! wait_job "$AB_A" '^release$' in_progress 360; then snap "$AB_A" A-timeout
    verdict_out "INCONCLUSIVE A 的 release 未进入执行（360s）"; exit 0; fi
  snap "$AB_A" A-exec-inprogress
  disp "$WFR" B ok 30 0; AB_B=$(runid "$WFR" B)
  for i in $(seq 1 48); do
    vs=$(gh api "repos/$REPO/actions/runs/$AB_B/jobs?per_page=100" \
      --jq '.jobs[] | select(.name=="verify") | .status+"/"+(.conclusion//"-")')
    bs=$(jfield "$AB_B" '^release$' status)
    if [ "$vs" = completed/success ] && [ "$bs" = queued ]; then ok=1; break; fi
    sleep 5
  done
  if [ -z "$ok" ]; then
    snap "$AB_A" AB-invalid-A; snap "$AB_B" AB-invalid-B
    verdict_out "INCONCLUSIVE 未建立 B 前置（B.verify=$vs B.release=$bs）"; exit 0
  fi
  snap "$AB_B" B-waiting
  note "PRECONDITION-OK: A.release in_progress; B verify=success & release=queued"
}

case "$CASE" in
c1|c2)
  AB 120; A=$AB_A; B=$AB_B
  CM=verify-reject; [ "$CASE" = c2 ] && CM=bind-mismatch
  disp "$WFR" C "$CM" 30 0; C=$(runid "$WFR" C)
  wait_run "$C" 360 || true; snap "$C" C-final
  wait_run "$A" 300 || true; wait_run "$B" 900 || true
  snap "$A" A-final; snap "$B" B-final
  slog "$A" '^release$' A-exec; slog "$B" '^release$' B-exec; slog "$C" '^verify$' C-verify
  cv=$(cond "$C" '^verify$'); cx=$(cond "$C" '^release$'); ar=$(cond "$A" '^release$'); br=$(cond "$B" '^release$')
  bs=$(jfield "$B" '^release$' started_at); ae=$(jfield "$A" '^release$' completed_at)
  note "RESULTS: C.verify=$cv C.release=$cx A.release=$ar B.release=$br B.started=$bs A.completed=$ae"
  ok=1
  [ "$cx" = skipped ] || ok=0
  [ "$ar" = success ] || ok=0
  [ "$br" = success ] || ok=0
  [ "$bs" \> "$ae" ] || ok=0
  if [ "$CASE" = c1 ]; then [ "$cv" = failure ] || ok=0; else [ "$cv" = success ] || ok=0; fi
  if [ "$ok" = 1 ]; then
    verdict_out "PASS: C 被拒（release=$cx）未替换等待中的 B；A 完成；B 保留并在 A 结束后执行"
  else
    verdict_out "FAIL: 行为不符（见 RESULTS 与 JSON 证据）"
  fi ;;
c3)
  disp "$WFR" F exec-fail 15 0; F=$(runid "$WFR" F)
  wait_run "$F" 360 || true; snap "$F" F-attempt1
  note "F attempt1: verify=$(cond "$F" '^verify$') release=$(cond "$F" '^release$') finalize=$(cond "$F" '^finalize$')"
  AB 120; A=$AB_A; B=$AB_B
  note "rerunning F (Re-run failed jobs)"
  gh run rerun "$F" --failed -R "$REPO" >/dev/null
  att=0
  for i in $(seq 1 24); do
    att=$(gh api "repos/$REPO/actions/runs/$F" --jq .run_attempt)
    [ "$att" = 2 ] && break; sleep 5
  done
  if [ "$att" != 2 ]; then snap "$F" F-rerun-not-started
    verdict_out "INCONCLUSIVE F 重跑未进入 attempt2"; exit 0; fi
  wait_run "$F" 600 || true
  gh api "repos/$REPO/actions/runs/$F/attempts/2" >"$EVROOT/F-attempt2-run.json"
  gh api "repos/$REPO/actions/runs/$F/attempts/2/jobs?per_page=100" >"$EVROOT/F-attempt2-jobs.json"
  snap "$F" F-final
  wait_run "$A" 300 || true; wait_run "$B" 900 || true
  snap "$A" A-final; snap "$B" B-final
  slog "$F" '^release$' F-exec-attempt2
  v2=$(gh api "repos/$REPO/actions/runs/$F/attempts/2/jobs?per_page=100" --jq '[.jobs[].name] | join(",")')
  fx=$(cond "$F" '^release$'); ar=$(cond "$A" '^release$'); br=$(cond "$B" '^release$')
  note "F attempt2 jobs=[$v2] release=$fx A=$ar B=$br"
  if echo "$v2" | grep -q verify; then VCHK=VERIFY-RERAN; else VCHK=verify-not-rerun; fi
  if [ "$VCHK" = verify-not-rerun ] && [ "$fx" = skipped ] && [ "$ar" = success ] && [ "$br" = success ]; then
    verdict_out "PASS: attempt2 复用旧授权输出被 job 级 if 阻止（release=skipped），verify 未重跑，B 保留"
  elif [ "$VCHK" = VERIFY-RERAN ]; then
    verdict_out "INCONCLUSIVE: verify 实际被重跑，未测到目标分支（输出复用场景）"
  else
    verdict_out "FAIL: 行为不符（VCHK=$VCHK release=$fx A=$ar B=$br）"
  fi ;;
c4)
  AB 120; A=$AB_A; B=$AB_B
  disp "$WFR" C ok 30 0; C=$(runid "$WFR" C)
  wait_run "$C" 900 || true; wait_run "$A" 300 || true
  snap "$C" C-final; snap "$A" A-final; snap "$B" B-final
  slog "$C" '^release$' C-exec; slog "$B" '^release$' B-exec
  br=$(cond "$B" '^release$'); cx=$(cond "$C" '^release$'); ar=$(cond "$A" '^release$')
  cs=$(jfield "$C" '^release$' started_at); ae=$(jfield "$A" '^release$' completed_at)
  note "RESULTS: B.release=$br C.release=$cx A.release=$ar C.started=$cs A.completed=$ae"
  if [ "$br" = cancelled ] && [ "$cx" = success ] && [ "$ar" = success ] && [ "$cs" \> "$ae" ]; then
    verdict_out "PASS: 合法 C 替换了等待中的 B（对照成立：C1-C3 的 B 保留不是因 C 未入组）"
  else
    verdict_out "FAIL/INCONCLUSIVE: 对照行为不符（B.release=$br，保存的 JSON 含原始字段）"
  fi ;;
c5)
  disp "$WFR" rel ok 120 0; R=$(runid "$WFR" rel)
  if ! wait_job "$R" '^release$' in_progress 360; then snap "$R" rel-timeout
    verdict_out "INCONCLUSIVE release 未进入执行"; exit 0; fi
  snap "$R" rel-inprogress
  disp "$WFM" mnt ok 30 0; M=$(runid "$WFM" mnt)
  wait_run "$R" 300 || true; wait_run "$M" 900 || true
  snap "$R" rel-final; snap "$M" mnt-final
  slog "$R" '^release$' rel-exec; slog "$M" '^maintenance$' mnt-exec
  rs=$(jfield "$R" '^release$' started_at); re=$(jfield "$R" '^release$' completed_at)
  ms=$(jfield "$M" '^maintenance$' started_at); me=$(jfield "$M" '^maintenance$' completed_at)
  note "INTERVALS: rel=[$rs,$re] mnt=[$ms,$me]"
  if [ "$ms" \> "$re" ]; then
    verdict_out "PASS: 跨 workflow 互斥（maintenance 起点 > release 终点，执行区间不重叠）"
  else
    verdict_out "FAIL/INCONCLUSIVE: 区间重叠或证据缺失"
  fi ;;
c6)
  disp "$WFR" A ok 30 75; A=$(runid "$WFR" A)
  if ! wait_job "$A" '^release$' completed 300; then snap "$A" A-timeout
    verdict_out "INCONCLUSIVE A 的 release 未完成"; exit 0; fi
  if ! wait_job "$A" '^finalize$' in_progress 240; then snap "$A" A-finalize-late
    verdict_out "INCONCLUSIVE finalize 未开始"; exit 0; fi
  snap "$A" A-finalize-holding
  disp "$WFR" B ok 20 0; B=$(runid "$WFR" B)
  wait_run "$A" 600 || true; wait_run "$B" 600 || true
  snap "$A" A-final; snap "$B" B-final
  slog "$A" '^finalize$' A-finalize; slog "$B" '^release$' B-exec
  bs=$(jfield "$B" '^release$' started_at); ae=$(jfield "$A" '^release$' completed_at)
  fsv=$(jfield "$A" '^finalize$' started_at); fe=$(jfield "$A" '^finalize$' completed_at)
  br=$(cond "$B" '^release$')
  note "TIMES: A.releaseEnd=$ae A.finalize=[$fsv,$fe] B.started=$bs B.result=$br"
  if [ "$bs" \> "$ae" ] && [ "$bs" \< "$fe" ] && [ "$br" = success ]; then
    verdict_out "PASS: B 在 A finalize 持有期间开始执行（组范围=执行 job，非整个 workflow）"
  else
    verdict_out "FAIL/INCONCLUSIVE: 见 TIMES 行"
  fi ;;
*) echo "未知 case：$CASE" >&2; exit 2 ;;
esac
note "case $CASE done"
