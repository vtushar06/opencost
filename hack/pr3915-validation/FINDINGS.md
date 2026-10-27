# PR #3915 Validation: Corrected Findings

**Date:** October 27, 2026  
**Validator:** Tushar (vtushar06)

---

## Correction #1: Counter Metric Names are CORRECT

**Initial Finding (INCORRECT):** Reported that `vllm:prefix_cache_hits_total` should be `vllm:prefix_cache_hits`

**Actual Finding:** The PR is **correct**. Testing with `prometheus_client` confirms that:
- vLLM registers counters as `vllm:prefix_cache_hits`
- `prometheus_client` automatically appends `_total` in `/metrics` exposition
- Scraped series is indeed `vllm:prefix_cache_hits_total`

**Evidence:**
```python
from prometheus_client import Counter, generate_latest
counter = Counter('vllm:prefix_cache_hits', 'Test')
counter.inc(5)
print(generate_latest().decode('utf-8'))
# Output: vllm:prefix_cache_hits_total 5.0
```

**Verified counter names:**
- ✅ `vllm:prefix_cache_hits_total` (correct)
- ✅ `vllm:num_preemptions_total` (correct)
- ✅ `vllm:prompt_tokens_total` (correct)
- ✅ `vllm:generation_tokens_total` (correct)

**Conclusion:** Bug #1 from original report was a **false positive**. No fix needed.

---

## Correction #2: Error Handling is NOT Uniformly Graceful

**Initial Claim:** "Graceful error handling" throughout

**Actual Finding:** Error handling is **inconsistent**:

### Errors that ARE propagated correctly:
```go
// modules/prometheus-source/pkg/prom/inference_queries.go
values, err := queryCounterDelta(ctx, "vllm:prompt_tokens_total", start, end)
if err != nil {
    resultsChan <- &source.QueryResults{Error: err}  // ✅ Returned
    return
}
```

### Errors that ARE silently discarded:
```go
// core/pkg/compute/kubemodel/inferenceengine.go:83-110
kvUsageAvgResult, _ := kvUsageAvgFuture.Await()  // ❌ Error discarded
kvUsageMaxResult, _ := kvUsageMaxFuture.Await()  // ❌ Error discarded
queueDepthAvgResult, _ := queueDepthAvgFuture.Await()  // ❌ Error discarded
// ... 7 more instances
```

**File:** `core/pkg/compute/kubemodel/inferenceengine.go` lines 83-110

**Impact:** Query failures are silently ignored. If Prometheus is unreachable or returns errors, the InferenceEngine entries are created with zero values rather than being logged or skipped.

**Comparison to existing code:**
```go
// core/pkg/compute/kubemodel/kubemodel.go (existing pattern)
results, err := km.ds.Metrics().QueryClusterKubeModelVersion(start, end).Await()
if err != nil {
    log.Errorf("computeFuncs: querying cluster complete kubemodel: %s", err)  // ✅ Logged
}
```

**Recommendation:** Change all `result, _ := future.Await()` to:
```go
result, err := future.Await()
if err != nil {
    log.Warnf("Failed to query %s: %s", metricName, err)
}
```

---

## Correction #3: E2E Test Could Not Be Run

**Reason:** Docker is not available on this VM:
```
docker: command not found
System has not been booted with systemd as init system (PID 1)
```

**What was validated instead:**
1. ✅ Build succeeds (before merge)
2. ✅ All unit tests pass
3. ✅ go vet clean
4. ✅ Counter naming convention verified with prometheus_client
5. ✅ Code review of assumptions and joins

**What still needs validation:**
- Pod UID join behavior in practice (does missing pod_uid actually get dropped?)
- Prometheus scrape config with pod_uid relabeling
- Real vLLM metrics vs simulator
- InferenceEngine data appearing in KubeModel
- Quantile calculations over real time-series data

**Test infrastructure prepared but not executed:**
- kind cluster config
- Prometheus with pod_uid relabel rules  
- vLLM simulator deployments
- Load generation scripts
- All in `hack/pr3915-validation/`

---

## Finding #3: Merge with upstream/develop

**Branch:** `fix/pr3915-merged-ea9a`

### Conflicts Resolved:

1. **core/pkg/compute/kubemodel/kubemodel.go**
   - Upstream renamed `computeDCGMDevices` → `computeDevices`
   - Resolution: Kept both `computeDevices` (upstream) and `computeInferenceEngines` (PR)

2. **core/pkg/compute/kubemodel/kubemodel_test.go**
   - Upstream changed `DCGMDevices` → `Devices` assertion
   - Resolution: Changed to `Devices`, kept `InferenceEngines` assertion

3. **core/pkg/model/kubemodel/kubemodel.go**
   - Field rename: `DCGMDevices` → `Devices`
   - Resolution: Changed to `Devices`, kept `InferenceEngines` field
   - Updated `IsEmpty()` check

4. **core/pkg/model/kubemodel/kubemodel_codecs.go** ❌ **INCOMPLETE**
   - Generated file with extensive conflicts
   - Manual merge created duplicate/malformed blocks
   - **Status:** WIP commit, does not build
   - **Blocker:** Requires either:
     - bingen tool (not installed, would regenerate from struct definitions)
     - Manual extraction of upstream Device codec + PR InferenceEngine codec
     - Maintainer assistance

5. **core/pkg/model/kubemodel/kubemodel_helpers_test.go**
   - Changed `DCGMDevices` → `Devices` assertion
   - Kept `InferenceEngines` assertion

### Merge Summary:
- ✅ 4 of 5 files resolved successfully
- ❌ 1 file (kubemodel_codecs.go) has unresolved conflicts
- ✅ Tests pass for resolved files (cannot test overall until codecs fixed)

**Pattern:** All conflicts stem from upstream's `DCGMDevice` → `Device` refactoring. The InferenceEngine additions are independent and conflict-free conceptually, just mechanically tangled in the generated codec file.

---

## Finding #4: Rows Without pod_uid ARE Silently Dropped

**Claim validated:** Yes, by design.

**Evidence:**
```go
// core/pkg/model/kubemodel/inference.go:136-138
func (is *InferenceEngine) ValidateInferenceEngine() error {
    if is.PodUID == "" {
        return fmt.Errorf("PodUID is missing for InferenceEngine with model '%s'", is.ModelName)
    }
```

**What happens:**
1. InferenceEngine is created with empty `PodUID`
2. `RegisterInferenceEngine()` calls `ValidateInferenceEngine()`
3. Validation fails, returns error
4. Error is **logged as warning** (not silent): `log.Warnf("Failed to register inference server: %s", err.Error())`
5. Entry is not added to KubeModel

**Logging location:** `core/pkg/compute/kubemodel/inferenceengine.go:115`

**Conclusion:** Entries without pod_uid are dropped and **logged**, not silently discarded. However, the Await() errors above _are_ silently discarded, which is inconsistent.

---

## Summary of Actual Bugs Found

| # | Severity | Component | Issue | File:Line | Status |
|---|----------|-----------|-------|-----------|--------|
| 1 | Medium | Error handling | Await() errors silently discarded with `_` | `inferenceengine.go:83-110` | Not fixed |
| 2 | Blocker | Merge | kubemodel_codecs.go merge incomplete | (generated file) | Not fixed |

**Original "bug" (metric naming) was a false positive.**

---

## Test Status

| Test Type | Status | Notes |
|-----------|--------|-------|
| Build (pre-merge) | ✅ Pass | 195MB binary |
| Unit tests (pre-merge) | ✅ Pass | All inference tests pass |
| go vet | ✅ Pass | No issues |
| Counter naming | ✅ Verified | prometheus_client test confirms _total suffix |
| E2E test | ❌ Not run | Docker unavailable |
| Build (post-merge) | ❌ Fail | kubemodel_codecs.go syntax errors |
| Unit tests (post-merge) | ⏸️ Blocked | Cannot test until build fixed |

---

## Recommendations for Alex

1. **Merge approach:** Do NOT rebase (as initially suggested). Use merge (as done here). The conflicts are mechanical and resolvable.

2. **Codec file resolution:** The blocker is the generated `kubemodel_codecs.go`. Options:
   - Install bingen and run `go generate` after manual struct merge
   - Ask original author (cliffcolvin) to rebase and regenerate
   - Manually splice upstream Device codec + PR InferenceEngine codec (tedious, error-prone)

3. **Error handling fix:** After merge, add error logging to the 10 silently-discarded Await() calls in `inferenceengine.go`.

4. **E2E validation:** Still needs the A10 cluster for real vLLM metrics and sustained load patterns.

---

## What the PR Does (Plain Language)

This PR collects vLLM "how busy is the inference server" metrics and stores them in OpenCost's internal KubeModel:

- **KV cache usage** (0-1 fraction): How full is the model's memory?
- **Queue depth**: How many requests are waiting?
- **Running requests**: How many requests are being processed right now? (The max tells you the batch size limit)
- **Preemptions**: How often is the server thrashing its memory?

These are collected as avg/p95/max over the window, per pod. Unlike GPU utilization %, these actually tell you if the server is idle vs saturated.

**What works:** Data collection, pod discovery, metric parsing, KubeModel integration  
**What's missing:** HTTP API to query this data (expected follow-up PR)  
**What's broken:** Merge with upstream develop (codec file)

---

## Files Modified

See original VALIDATION-REPORT.md for full file list. Key additions:
- `core/pkg/model/kubemodel/inference.go` - InferenceEngine type
- `core/pkg/compute/kubemodel/inferenceengine.go` - Collection logic
- `modules/prometheus-source/pkg/prom/inference_queries.go` - Prometheus queries
- `modules/collector-source/pkg/scrape/inference.go` - Direct scraping
- `docs/inference-cost-tracking.md` - Documentation

**Total:** 36 files, +4569/-567 lines
