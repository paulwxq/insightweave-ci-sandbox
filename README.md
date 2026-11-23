# insightweave-ci-sandbox

GitHub Actions 调度实验仓（依 [doc 15.1 部署并发授权门禁测试需求] 建立的独立实验环境）。

## 边界（硬约束）

- 只包含最小实验工作流、测试驱动脚本与本说明；**不含任何 InsightWeave 业务源码、运行配置、Secret 或凭据**。
- 所有 job 使用标准 GitHub 托管 Runner（ubuntu-latest）；不使用 self-hosted，不连接本地 Runner，不执行 Docker 或真实部署。
- 不修改 InsightWeave 仓库的任何工作流；本仓与生产完全隔离。
- 并发组一律使用 `insightweave-concurrency-probe-<batch>-<case>` 前缀（工作流内有守卫步骤拒绝其他组名，尤其拒绝生产组名）。
- 不提高付费预算：公开仓托管 Runner 免费额度。

## 文件

| 文件 | 用途 |
| --- | --- |
| `.github/workflows/concurrency-probe.yml` | release 模拟：verify（组外，产生授权绑定输出）→ release（执行 job：job 级四条件 if + 并发组 + cancel-in-progress:false）→ finalize（组外，严格结果检查）。模式：ok / verify-reject / bind-mismatch / no-binding / exec-fail |
| `.github/workflows/concurrency-probe-maint.yml` | 维护模拟（C5 跨 workflow 互斥用），结构与 release 模拟一致，执行 job 为 maintenance |
| `run_probe.sh` | 驱动与取证：`./run_probe.sh <owner/repo> <c1..c6> [batch]`，产物为分阶段 run/jobs JSON、job 日志、timeline、verdict |
| `check_structure.py` | 工作流结构检查（§6） |

## 运行

```bash
gh workflow run concurrency-probe.yml -R paulwxq/insightweave-ci-sandbox --ref main \
  -f group=insightweave-concurrency-probe-<batch>-<case> \
  -f tag=<batch>-<case>-<role> -f mode=<mode> [-f hold_seconds=120] [-f finalize_hold_seconds=0]
```

或直接用驱动脚本逐案例执行。实验报告与证据不入本仓。
