# PR #3915 Validation Summary

**Validation completed:** October 27, 2026  
**Reviewer:** Tushar (vtushar06)  
**Full report:** [VALIDATION-REPORT.md](./VALIDATION-REPORT.md)  
**Draft PR:** https://github.com/vtushar06/opencost/pull/1

---

## Quick Status

✅ **Code builds cleanly**  
✅ **All unit tests pass**  
✅ **go vet clean**  
✅ **vLLM metric names verified** (1 typo found)  
✅ **Design is sound and well-tested**  
⚠️ **Needs rebase** (46 commits behind, 5 merge conflicts)  
⚠️ **1 medium-severity bug** (fixable in 5 minutes)

---

## Bugs Found

### 🐛 Bug #1: Wrong vLLM Metric Name (Medium Severity)

**Problem:**  
Code queries `vllm:prefix_cache_hits_total` but vLLM v1 actually exposes `vllm:prefix_cache_hits` (no `_total` suffix).

**Impact:**  
Cache hit metrics will always return empty, `cacheSavingsFraction` will always be 0.

**Files to fix:**
- `modules/prometheus-source/pkg/prom/inference_queries.go:103`
- `modules/collector-source/pkg/metric/metrics.go`

**Fix:** Simple string replacement - 2 lines of code.

---

## What Works

✅ Pod discovery by `llm-d.ai/model` label  
✅ Prometheus scrape config (pod_uid relabeling documented)  
✅ vLLM gauge queries (KV cache, queue, running requests, preemptions)  
✅ Counter reset recovery (window max approach)  
✅ Non-fatal joins (graceful degradation)  
✅ Engine index keying (handles vLLM data parallelism)  
✅ Test coverage comprehensive

---

## What Still Needs the A10 Cluster

1. **Max_num_seqs inference validation** - Does RunningRequestsMax actually capture the concurrent-sequence limit under sustained queue pressure?
2. **Real preemption behavior** - Counter reset recovery is tested, but needs real KV thrashing
3. **MIG instance scenarios** - Should work (each MIG runs its own engine), but unverified
4. **DCGM correlation** - Do InferenceEngine KV usage and DCGM memory occupancy correlate?
5. **Sustained load patterns** - Simulator can't replicate hours of production traffic

---

## Merge Blockers

1. ✅ **Rebase on develop** (resolve 5 kubemodel conflicts - standard rebase)
2. ✅ **Fix metric name** `vllm:prefix_cache_hits_total` → `vllm:prefix_cache_hits`

That's it. Everything else is solid.

---

## Recommended Follow-ups (Not Blockers)

1. Add REST API endpoints (`/inferenceEngine?window=1h&aggregate=model_name`)
2. Add Prometheus `pod_uid` startup check (warns if relabel rule missing)
3. Helm chart updates (scrape config examples)
4. Grafana dashboards (KV usage, queue alerts)
5. Run extended validation on OKE A10 cluster

---

## For Your Meeting with Alex

**Key points:**

1. **The PR is fundamentally sound.** Design follows OpenCost patterns, test coverage is good, and the assumptions about vLLM metrics are correct.

2. **One fixable bug:** Metric name has `_total` suffix that vLLM doesn't use. Easy fix.

3. **Merge conflicts are expected** - the PR touches the kubemodel package which has seen concurrent development. Standard rebase will resolve them.

4. **What the PR does:** Collects vLLM scheduler signals (KV memory usage, queue depth, running batch size, preemptions) and stores them per-pod in the KubeModel. This is the foundation for capacity analysis separate from raw GPU utilization.

5. **What's missing (intentionally):** No HTTP API yet to query this data. That's expected - this PR is the data collection layer. User-facing API should be a follow-up.

6. **Why the A10 cluster still matters:** The local validation can verify code correctness, but can't test things like:
   - Does the "inferred max batch size" heuristic actually work under sustained load?
   - Real vLLM preemption behavior
   - MIG instances
   - DCGM correlation

7. **Timeline to merge:** Rebase + metric name fix = probably 1-2 hours of work. The hard work is already done.

---

## Validation Artifacts

- **Report:** `hack/pr3915-validation/VALIDATION-REPORT.md` (full 13-section analysis)
- **Test scripts:** `hack/pr3915-validation/run-e2e-test.sh`
- **Draft PR:** https://github.com/vtushar06/opencost/pull/1
- **Branch:** `fix/pr3915-validation-ea9a` on vtushar06/opencost

All pushed to your fork and ready to reference in discussions.

---

## Bottom Line

**Status:** Ready for merge after rebase + 1 metric name fix.  
**Confidence:** High - the code is well-written and follows established patterns.  
**Risk:** Low - comprehensive tests, graceful failure modes, well-documented.

The foundation is solid. Ship it (after the fixes), then build the user-facing API on top.
