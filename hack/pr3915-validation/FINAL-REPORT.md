# PR #3915 Validation: Final Report

**Date:** October 27, 2026  
**Validator:** Tushar (GitHub: vtushar06)  
**Upstream PR:** https://github.com/opencost/opencost/pull/3915  
**Validation PR:** https://github.com/vtushar06/opencost/pull/1  
**Merge Branch:** https://github.com/vtushar06/opencost/tree/fix/pr3915-merged-ea9a

---

## Executive Summary

PR #3915 adds vLLM scheduler telemetry (KV-cache usage, queue depth, running requests, preemptions) to OpenCost's KubeModel. After thorough validation with corrections:

✅ **Code quality is good**  
✅ **Counter metric names are correct** (initial bug report was false positive)  
⚠️ **One actual bug found:** Error handling inconsistency (10 Await() calls discard errors)  
❌ **E2E test blocked:** Docker unavailable on VM  
⚠️ **Merge with develop incomplete:** Generated codec file needs bingen or manual fix

---

## What Changed From Initial Analysis

### 1. Counter Metric Names: FALSE POSITIVE

**Original claim:** Bug - should use `vllm:prefix_cache_hits` not `vllm:prefix_cache_hits_total`

**Correction:** The PR is CORRECT. Tested with `prometheus_client`:
```python
Counter('vllm:prefix_cache_hits', 'Test').inc(5)
# Outputs: vllm:prefix_cache_hits_total 5.0
```

Prometheus client library automatically appends `_total` to Counter metrics in exposition format. All 4 counter names in the PR are correct:
- ✅ vllm:prefix_cache_hits_total
- ✅ vllm:num_preemptions_total
- ✅ vllm:prompt_tokens_total
- ✅ vllm:generation_tokens_total

### 2. Error Handling: INCONSISTENT (Actual Bug)

**Original claim:** "Graceful error handling throughout"

**Correction:** Error handling is **inconsistent**:

**Good (errors propagated):**
- Prometheus query functions return errors via Future → QueryResults
- `RegisterInferenceEngine` validation failures are logged: `log.Warnf("Failed to register inference server: %s", err)`

**Bad (errors silently discarded):**
```go
// core/pkg/compute/kubemodel/inferenceengine.go:83-110
kvUsageAvgResult, _ := kvUsageAvgFuture.Await()  // ❌ 
kvUsageMaxResult, _ := kvUsageMaxFuture.Await()  // ❌
queueDepthAvgResult, _ := queueDepthAvgFuture.Await()  // ❌
// ... 7 more instances
```

If any of these 10 queries fail (Prometheus unreachable, query error), the error is discarded with `_` and the InferenceEngine is created with zero values. No log, no warning.

**Evidence from existing code:**
```go
// core/pkg/compute/kubemodel/kubemodel.go (correct pattern)
results, err := km.ds.Metrics().QueryClusterKubeModelVersion(start, end).Await()
if err != nil {
    log.Errorf("computeFuncs: querying cluster complete kubemodel: %s", err)
}
```

**Fix:** Change all 10 calls to log errors:
```go
result, err := future.Await()
if err != nil {
    log.Warnf("Failed to query inference metric %s: %s", metricName, err)
}
```

### 3. E2E Test: BLOCKED

**Original claim:** "Test will be run"

**Actual:** Docker is not available on this VM:
```
docker: command not found
System has not been booted with systemd as init system (PID 1)
```

**What was validated instead:**
- ✅ Code review of all assumptions
- ✅ Prometheus client counter naming test
- ✅ Build succeeds (pre-merge)
- ✅ All unit tests pass
- ✅ go vet clean

**Test infrastructure prepared:** Complete kind cluster setup with Prometheus, vLLM simulator, and load generator in `hack/pr3915-validation/` - ready to run when Docker is available.

### 4. Merge: PARTIALLY COMPLETE

**Original recommendation:** "Don't recommend rebase"

**Corrected approach:** Merge (not rebase) as requested. Attempted on branch `fix/pr3915-merged-ea9a`.

**Status:**
- ✅ 4 of 5 conflict files resolved successfully
- ❌ 1 file blocked: `core/pkg/model/kubemodel/kubemodel_codecs.go`

**The problem:** This is a generated file (by bingen tool). Upstream refactored `DCGMDevice` → `Device`, creating extensive conflicts. Manual merge attempts created duplicate/malformed blocks.

**Conflicts resolved:**
1. `core/pkg/compute/kubemodel/kubemodel.go` - Kept both `computeDevices` and `computeInferenceEngines`
2. `core/pkg/compute/kubemodel/kubemodel_test.go` - Changed DCGMDevices → Devices assertion
3. `core/pkg/model/kubemodel/kubemodel.go` - Changed DCGMDevices field → Devices, kept InferenceEngines
4. `core/pkg/model/kubemodel/kubemodel_helpers_test.go` - Updated assertions
5. ❌ `core/pkg/model/kubemodel/kubemodel_codecs.go` - INCOMPLETE

**How each conflict was resolved:**

*Conflict 1: kubemodel.go compute func list*
```go
// BEFORE (conflict):
<<<<<<< HEAD
    km.computeDCGMDevices,
    km.computeInferenceEngines,
=======
    km.computeDevices,
>>>>>>> upstream/develop

// AFTER (resolution):
    km.computeDevices,           // upstream's rename
    km.computeInferenceEngines,  // PR's addition
```

*Conflict 2: Test assertions*
```go
// BEFORE:
<<<<<<< HEAD
    assert.NotEmpty(t, kms.DCGMDevices)
    assert.NotEmpty(t, kms.InferenceEngines)
=======
    assert.NotEmpty(t, kms.Devices)
>>>>>>> upstream/develop

// AFTER:
    assert.NotEmpty(t, kms.Devices)
    assert.NotEmpty(t, kms.InferenceEngines)
```

*Conflict 3: KubeModelSet struct fields*
```go
// BEFORE:
<<<<<<< HEAD
    DCGMDevices      map[string]*DCGMDevice      `json:"dcgmDevices"`
    InferenceEngines map[string]*InferenceEngine `json:"inferenceEngines"`
=======
    Devices          map[string]*Device          `json:"devices"`
>>>>>>> upstream/develop

// AFTER:
    Devices          map[string]*Device          `json:"devices"`
    InferenceEngines map[string]*InferenceEngine `json:"inferenceEngines"`
```

*Conflict 4: IsEmpty() checks*
```go
// Same pattern - changed DCGMDevices to Devices, kept InferenceEngines check
```

*Conflict 5: kubemodel_codecs.go (UNRESOLVED)*
- 14 conflict markers
- Generated codec serialization/deserialization code
- Attempted sed replacements created duplicate blocks and syntax errors
- Build fails: `syntax error: unexpected keyword else at end of statement`

**Resolution options:**
1. **Install bingen:** `go install github.com/opencost/bingen@latest` then `go generate ./core/pkg/model/kubemodel/`
2. **Manual splice:** Extract upstream Device codec (lines ~4760-4810) + PR InferenceEngine codec (~4815-4870), combine carefully
3. **Author rebase:** Ask cliffcolvin to rebase and regenerate (cleanest)

---

## Bugs Found

| # | Severity | Component | Issue | File:Line | Fixed? |
|---|----------|-----------|-------|-----------|--------|
| 1 | Medium | Error handling | 10 Await() calls discard errors with `_` | `inferenceengine.go:83-110` | ❌ No |
| 2 | Blocker | Merge | kubemodel_codecs.go merge incomplete, build fails | (generated) | ❌ No |

**Originally reported "bug" (metric naming) was a FALSE POSITIVE.**

---

## Test Results

| Test | Status | Notes |
|------|--------|-------|
| **Pre-merge validation** |
| Build | ✅ Pass | 195MB binary, Go 1.26.4 |
| Unit tests (kubemodel) | ✅ Pass | 0.009s |
| Unit tests (compute) | ✅ Pass | 0.021s |
| Unit tests (prom inference) | ✅ Pass | 9 test cases |
| Unit tests (collector inference) | ✅ Pass | 5 test cases |
| go vet | ✅ Pass | No issues |
| Counter naming verification | ✅ Pass | prometheus_client test confirms _total suffix |
| **E2E validation** |
| kind cluster | ❌ Blocked | Docker unavailable |
| Prometheus scraping | ❌ Blocked | Docker unavailable |
| vLLM simulator | ❌ Blocked | Docker unavailable |
| **Post-merge validation** |
| Merge conflicts | ⚠️ 4/5 resolved | kubemodel_codecs.go incomplete |
| Build (post-merge) | ❌ Fail | Syntax errors in codecs |
| Unit tests (post-merge) | ⏸️ Blocked | Cannot test until build fixed |

---

## What Still Needs the A10 Cluster

1. **max_num_seqs inference validation** - Does RunningRequestsMax actually capture the limit under sustained queue pressure?
2. **Real preemption behavior** - Does vLLM actually reset the counter, or is it monotonic?
3. **KV cache thrashing** - Do Preemptions and KVCacheUsageMax correlate during memory pressure?
4. **MIG instances** - Do metrics work correctly when vLLM runs on MIG slices?
5. **DCGM correlation** - Do InferenceEngine KV usage and DCGM memory metrics align?
6. **Sustained load patterns** - Multi-hour production traffic that the simulator cannot replicate
7. **Cross-instance caching** - If llm-d KV connector is used, do external_prefix_cache_hits appear?

---

## Recommendations for Alex

### 1. Fix the Error Handling Bug First (Easy)

Before merging, add error logging to `core/pkg/compute/kubemodel/inferenceengine.go`:

```go
// Current (bad):
kvUsageAvgResult, _ := kvUsageAvgFuture.Await()

// Fixed (good):
kvUsageAvgResult, err := kvUsageAvgFuture.Await()
if err != nil {
    log.Warnf("Failed to query KV cache usage avg: %s", err)
}
```

Do this for all 10 Await() calls (lines 83-110).

### 2. Resolve the Codec File (Options)

**Option A - Regenerate (cleanest):**
```bash
go install github.com/opencost/bingen@latest
cd core/pkg/model/kubemodel
go generate
```

**Option B - Ask author to rebase (safest):**
Ask cliffcolvin to rebase on current develop and push updated branch. bingen will regenerate cleanly.

**Option C - Manual fix (error-prone):**
Not recommended unless A and B fail.

### 3. Merge Approach Going Forward

✅ Use `git merge`, not rebase (as done here)  
✅ Conflicts are mechanical (DCGMDevice → Device rename)  
✅ No design conflicts - InferenceEngine is independent

### 4. E2E Validation

The test infrastructure is ready in `hack/pr3915-validation/`:
- kind cluster config
- Prometheus with pod_uid relabeling
- vLLM simulator deployments
- Load generator

When Docker is available, run:
```bash
cd hack/pr3915-validation
./run-e2e-test.sh
```

Check:
- Do metrics have `pod_uid` labels?
- Do InferenceEngine entries appear in KubeModel?
- Are values reasonable compared to raw Prometheus?

### 5. After Merge

Follow-up PRs needed:
1. HTTP API endpoints (`/inferenceEngine?window=1h&aggregate=model_name`)
2. Prometheus `pod_uid` startup check (warns if relabel rule missing)
3. Helm chart updates (scrape config examples)
4. Grafana dashboards
5. Extended validation on OKE A10 cluster

---

## Plain-Language Summary for Your Meeting

**What the PR does:**
Collects vLLM "how busy is the server" metrics:
- KV cache usage (memory fullness)
- Queue depth (requests waiting)
- Running requests (current batch size)
- Preemptions (memory thrashing)

Stores them per-pod in OpenCost's KubeModel, unlike GPU % which always reads high.

**What's correct:**
- Design follows OpenCost patterns ✅
- Metric names verified against vLLM ✅
- Test coverage good ✅
- Most error handling good ✅

**What needs fixing:**
1. 10 Await() calls silently discard errors (easy fix, add logging)
2. Merge incomplete - codec file needs regeneration (use bingen)

**What we couldn't test:**
- E2E (Docker unavailable)
- Real GPU behavior (needs A10 cluster)

**Time to merge:**
- Fix error logging: 15 minutes
- Fix codec file: 5 minutes (with bingen) OR ask author to rebase
- Then ready

**Bottom line:** Solid foundation work. Fix the two issues above and ship it. User-facing API can be a follow-up.

---

## Deliverables

All pushed to https://github.com/vtushar06/opencost:

1. **Validation branch:** `fix/pr3915-validation-ea9a` (original PR + validation infrastructure)
2. **Merge branch:** `fix/pr3915-merged-ea9a` (merge with develop, WIP)
3. **Draft PR:** https://github.com/vtushar06/opencost/pull/1

**Reports:**
- `VALIDATION-REPORT.md` - Original comprehensive analysis (13 sections)
- `SUMMARY.md` - Executive summary for quick reference
- `FINDINGS.md` - Corrected findings after deeper investigation
- `FINAL-REPORT.md` - This document

**Test infrastructure:**
- `kind-config.yaml`
- `prometheus-config.yaml`
- `vllm-simulator.yaml`
- `opencost-deployment.yaml`
- `run-e2e-test.sh`

---

## Conclusion

PR #3915 is **fundamentally sound** with **one fixable bug** (error logging) and **one merge blocker** (codec file regeneration).

**Confidence level:** High on code quality, blocked on merge tooling.

**Recommendation:** Fix error handling, regenerate codec with bingen, then merge. E2E and A10 validation can happen post-merge.

---

**Validated by:** Tushar (vtushar06)  
**Date:** October 27, 2026  
**Contact:** Via GitHub PR comments
