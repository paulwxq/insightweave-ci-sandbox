#!/usr/bin/env python3
"""doc 15.1 实验工作流结构检查（§6）：只做结构断言，不做字符串搜索代替。"""
import re, sys
import yaml

import os
BASE = os.path.dirname(os.path.abspath(__file__))
FILES = {
    "concurrency-probe.yml": "release",
    "concurrency-probe-maint.yml": "maintenance",
}
fail = 0
def check(cond, msg):
    global fail
    print(("OK  " if cond else "FAIL") + "  " + msg)
    if not cond:
        fail += 1

for fname, exec_job in FILES.items():
    doc = yaml.safe_load(open(f"{BASE}/{fname}", encoding="utf-8"))
    print(f"== {fname} ==")
    check(isinstance(doc, dict), "YAML 解析为映射")
    check("concurrency" not in doc, "workflow 顶层无 concurrency（避免 verify 前进入组）")
    jobs = doc.get("jobs", {})
    check(set(jobs) == {"verify", exec_job, "finalize"}, f"jobs 恰为 verify/{exec_job}/finalize")
    check("concurrency" not in jobs["verify"], "verify 不在并发组")
    check("concurrency" not in jobs["finalize"], "finalize 不在并发组")
    conc = jobs[exec_job].get("concurrency")
    check(isinstance(conc, dict) and conc.get("group") == "${{ inputs.group }}",
          f"{exec_job} 组名固定为 inputs.group（同案例跨 workflow 字符串一致）")
    check(isinstance(conc, dict) and conc.get("cancel-in-progress") is False,
          f"{exec_job} cancel-in-progress 布尔 false")
    check(not re.search(r"run_id", str(conc.get("group"))), "组名不含 run_id（否则失去互斥意义）")
    iftext = str(jobs[exec_job].get("if", ""))
    for frag in ["needs.verify.result == 'success'",
                 "needs.verify.outputs.authorized_private_run_id == github.run_id",
                 "needs.verify.outputs.authorized_private_attempt == github.run_attempt",
                 "needs.verify.outputs.authorized_triggering_actor == github.triggering_actor"]:
        check(frag in iftext, f"{exec_job} job 级 if 含：{frag[:52]}…")
    check(jobs[exec_job].get("needs") == "verify", f"{exec_job} needs verify（绑定在 job 层非首 step）")
    check(jobs[exec_job]["runs-on"] == "ubuntu-latest", f"{exec_job} 用标准托管 Runner")
    check(str(jobs["verify"].get("runs-on")) == "ubuntu-latest", "verify 用标准托管 Runner")
    check(doc.get("permissions") == {}, "workflow permissions 为空（最小令牌）")
    fin = jobs["finalize"]
    check(fin.get("needs") == ["verify", exec_job] and "${{ always() }}" in str(fin.get("if")),
          "finalize needs [verify, exec] 且 always()")
    finenv = str(fin.get("env", {}).get("STRICT_OK", ""))
    for frag in ["needs.verify.result == 'success'", f"needs.{exec_job}.result == 'success'",
                 "authorized_private_run_id == github.run_id",
                 "authorized_private_attempt == github.run_attempt"]:
        check(frag in finenv, f"finalize 严格检查含：{frag[:52]}…")

print("STRUCT RESULT:", "FAIL" if fail else "ALL OK")
sys.exit(1 if fail else 0)
