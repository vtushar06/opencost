# OpenCost MCP & Plugin System Contribution Roadmap

**Contributor Goal:** Systematic contributions over 2 months to demonstrate Go expertise, understanding of cloud-native systems, and commitment to the project.

---

## Phase 1: Quick Wins (Week 1-2)
*Goal: Get your first PRs merged, build rapport with maintainers*

### Issue #1: Logging Consistency Fix
**File:** `pkg/mcp/server.go` (Lines 773, 843)
**Type:** Code Quality
**Effort:** ~30 minutes
**Title:** `fix(mcp): Replace fmt.Printf with structured logging`

```markdown
**Problem**
The MCP server uses `fmt.Printf()` for warnings instead of the project's logging infrastructure (`log.Warnf`), which:
- Bypasses log level configuration
- Outputs to stdout instead of structured logs
- Is inconsistent with the rest of the codebase

**Location**
- `pkg/mcp/server.go:773`
- `pkg/mcp/server.go:843`

**Proposed Fix**
Replace `fmt.Printf("Warning: ...")` with `log.Warnf("...")`.

I'm happy to submit a PR for this small improvement.
```

---

### Issue #2: Fix Silent Failure in Plugin Config Loading
**File:** `pkg/customcost/pipelineservice.go` (Lines 37-40)
**Type:** Bug Fix
**Effort:** ~1 hour
**Title:** `fix(plugins): Return error when plugin config directory is unreadable`

```markdown
**Describe the bug**
When `os.ReadDir(configDir)` fails, the error is logged but not returned. The function silently continues with an empty plugin list, making debugging difficult.

**Location**
`pkg/customcost/pipelineservice.go:37-40`

**Current Behavior**
```go
configFiles, err := os.ReadDir(configDir)
if err != nil {
    log.Errorf("error reading files in directory %s: %v", configDir, err)
    // Missing return! Continues with empty slice
}
```

**Expected Behavior**
Return the error so callers can handle the failure appropriately.

**Proposed Fix**
```go
if err != nil {
    log.Errorf("error reading files in directory %s: %v", configDir, err)
    return nil, fmt.Errorf("failed to read plugin config directory: %w", err)
}
```
```

---

## Phase 2: Stability Fixes (Week 3-4)
*Goal: Show you understand Go idioms, error handling, and concurrency*

### Issue #3: Graceful Shutdown for MCP Server
**File:** `pkg/cmd/costmodel/costmodel.go` (Lines 305-313)
**Type:** Resource Leak / Bug
**Effort:** ~2-3 hours
**Title:** `fix(mcp): Implement graceful shutdown for MCP HTTP server`

```markdown
**Describe the bug**
The MCP server lacks a graceful shutdown mechanism. When the application terminates, the HTTP server continues running until forcefully killed, which can lead to:
- Dropped connections mid-request
- Resource leaks
- Potential data corruption for in-flight queries

**Location**
`pkg/cmd/costmodel/costmodel.go` (Lines 305-313)

**Current Code**
```go
go func() {
    if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
        log.Errorf("MCP server failed: %v", err)
    }
}()
// Context is passed but never used for shutdown
```

**Expected Behavior**
The server should listen for context cancellation and gracefully drain connections.

**Proposed Solution**
```go
// Graceful shutdown goroutine
go func() {
    <-ctx.Done()
    log.Info("Shutting down MCP server...")
    shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
    defer cancel()
    if err := server.Shutdown(shutdownCtx); err != nil {
        log.Errorf("MCP server shutdown error: %v", err)
    }
}()
```

I'm happy to submit a PR for this fix!
```

---

### Issue #4: Nil Pointer Protection in Cloud Cost Transformation
**File:** `pkg/mcp/server.go` (Lines 879-880, 905-906)
**Type:** Bug / Crash Prevention
**Effort:** ~2 hours
**Title:** `fix(mcp): Add nil checks to prevent panic in cloud cost transformation`

```markdown
**Describe the bug**
The `transformCloudCostSetRange` function dereferences `ccSet.Window.Start()` and `ccSet.Window.End()` without nil checks, which can cause a panic if the window is malformed.

**Location**
`pkg/mcp/server.go:879-880, 905-906`

**Current Code**
```go
Window: &TimeWindow{
    Start: *ccSet.Window.Start(),  // Panic if nil!
    End:   *ccSet.Window.End(),    // Panic if nil!
},
```

**Impact**
A malformed cloud cost response from any cloud provider integration could crash the entire MCP server.

**Proposed Solution**
```go
if ccSet.Window == nil {
    log.Warnf("Skipping cloud cost set with nil window")
    continue
}
startTime := ccSet.Window.Start()
endTime := ccSet.Window.End()
if startTime == nil || endTime == nil {
    log.Warnf("Skipping cloud cost set with incomplete window")
    continue
}
```
```

---

### Issue #5: Context Propagation for Query Timeouts
**File:** `pkg/mcp/server.go` (Line 741)
**Type:** Bug / Reliability
**Effort:** ~3 hours
**Title:** `fix(mcp): Propagate request context to cloud cost queries`

```markdown
**Describe the bug**
The MCP server uses `context.TODO()` instead of propagating the request context, preventing proper timeout handling and cancellation.

**Location**
`pkg/mcp/server.go:741`

**Current Code**
```go
ccsr, err := s.cloudQuerier.Query(context.TODO(), request)
```

**Impact**
- Queries cannot be cancelled if client disconnects
- No timeout enforcement - queries can hang indefinitely
- Resource waste from orphaned queries

**Proposed Solution**
1. Update `ProcessMCPRequest` signature to accept context
2. Propagate context through the call chain
3. Add a reasonable timeout for cloud cost queries

```go
func (s *MCPServer) ProcessMCPRequest(ctx context.Context, request *MCPRequest) (*MCPResponse, error) {
    // ...
    queryCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
    defer cancel()
    ccsr, err := s.cloudQuerier.Query(queryCtx, request)
}
```
```

---

## Phase 3: Security Hardening (Week 5-6)
*Goal: Demonstrate security awareness - highly valued in CNCF projects*

### Issue #6: Safe Type Assertion in Plugin Loader
**File:** `pkg/customcost/ingestor.go` (Line 188)
**Type:** Security / Crash Prevention
**Effort:** ~2 hours
**Title:** `fix(plugins): Use safe type assertion to prevent server crash`

```markdown
**Describe the bug**
An unsafe type assertion in the plugin loader can crash the entire OpenCost server if a plugin returns an unexpected type.

**Location**
`pkg/customcost/ingestor.go:188`

**Current Code**
```go
custCostSrc := raw.(ocplugin.CustomCostSource)  // Panics on type mismatch!
```

**Impact**
A malformed or malicious plugin can crash the entire OpenCost server by returning an object that doesn't implement `CustomCostSource`.

**Proposed Solution**
```go
custCostSrc, ok := raw.(ocplugin.CustomCostSource)
if !ok {
    log.Errorf("plugin %s returned invalid type: expected CustomCostSource, got %T", domain, raw)
    return
}
```
```

---

### Issue #7: Path Traversal Prevention in Plugin Names
**File:** `pkg/customcost/pipelineservice.go` (Lines 50, 68, 95)
**Type:** Security
**Effort:** ~3 hours
**Title:** `security(plugins): Validate plugin names to prevent path traversal`

```markdown
**Describe the bug**
Plugin names are extracted directly from config filenames without sanitization. A malicious filename like `../../../evil_config.json` could result in arbitrary binary execution from outside the intended plugin directory.

**Location**
`pkg/customcost/pipelineservice.go:50, 68, 95`

**Attack Vector**
1. Attacker places malicious config: `../../../tmp/evil_config.json`
2. Plugin name becomes: `../../../tmp/evil`
3. Executed path: `/opt/opencost/plugin/bin/../../../tmp/evil.ocplugin.linux.amd64`
4. Arbitrary code execution outside plugin directory

**Proposed Solution**
```go
pluginName := fileParts[0]

// Validate plugin name doesn't contain path traversal sequences
if strings.Contains(pluginName, "..") ||
   strings.ContainsAny(pluginName, "/\\") ||
   strings.Contains(pluginName, "\x00") {
    return nil, fmt.Errorf("invalid plugin name %q: contains illegal characters", pluginName)
}

// Ensure the final path is within the expected directory
cleanPath := filepath.Clean(filepath.Join(execDir, pluginName))
if !strings.HasPrefix(cleanPath, filepath.Clean(execDir)) {
    return nil, fmt.Errorf("plugin path escapes allowed directory: %s", cleanPath)
}
```
```

---

### Issue #8: Add Timeout to Plugin gRPC Calls
**File:** `core/pkg/plugin/grpc.go` (Line 13)
**Type:** Security / DoS Prevention
**Effort:** ~2 hours
**Title:** `fix(plugins): Add timeout to gRPC calls to prevent hung plugins`

```markdown
**Describe the bug**
Plugin gRPC calls use `context.Background()` with no timeout. A hung or malicious plugin can block the OpenCost server indefinitely.

**Location**
`core/pkg/plugin/grpc.go:13`

**Current Code**
```go
func (m *GRPCClient) GetCustomCosts(req *pb.CustomCostRequest) []*pb.CustomCostResponse {
    resp, err := m.client.GetCustomCosts(context.Background(), req)  // No timeout!
```

**Impact**
- Single hung plugin blocks custom cost ingestion for all plugins
- Potential DoS vector via malicious plugin
- No way to recover without restarting OpenCost

**Proposed Solution**
```go
func (m *GRPCClient) GetCustomCosts(req *pb.CustomCostRequest) []*pb.CustomCostResponse {
    ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
    defer cancel()
    resp, err := m.client.GetCustomCosts(ctx, req)
```
```

---

## Phase 4: Resource Management (Week 7)
*Goal: Show you understand process lifecycle management*

### Issue #9: Plugin Process Cleanup on Shutdown
**File:** `pkg/customcost/ingestor.go` (Lines 234-269)
**Type:** Resource Leak
**Effort:** ~3-4 hours
**Title:** `fix(plugins): Kill plugin processes on ingestor shutdown`

```markdown
**Describe the bug**
The `Stop()` method terminates the ingestor goroutines but never kills the plugin client processes. This results in zombie processes that continue consuming resources.

**Location**
`pkg/customcost/ingestor.go:234-269`

**Current Behavior**
```go
func (ing *CustomCostIngestor) Stop() {
    // Stops goroutines via channels...
    ing.isRunning.Store(false)
    ing.isStopping.Store(false)
    // MISSING: Plugin process cleanup!
}
```

**Impact**
- Plugin processes become orphaned zombies
- Memory and CPU leak over time
- Repeated restarts accumulate dead processes

**Proposed Solution**
```go
func (ing *CustomCostIngestor) Stop() {
    // ... existing goroutine shutdown code ...

    // Kill all plugin processes
    for name, client := range ing.plugins {
        log.Infof("Stopping plugin: %s", name)
        client.Kill()
    }

    ing.isRunning.Store(false)
    ing.isStopping.Store(false)
}
```
```

---

## Phase 5: Feature Enhancement (Week 8)
*Goal: Show initiative by adding value, not just fixing bugs*

### Issue #10: Add Dedicated Savings Recommendations Tool
**File:** `pkg/cmd/costmodel/costmodel.go`
**Type:** Feature Enhancement
**Effort:** ~1-2 days
**Title:** `feat(mcp): Add dedicated get_savings_recommendations tool`

```markdown
**Is your feature request related to a problem?**
The current MCP server includes savings data within the `get_efficiency` tool, but AI agents may not discover cost-saving recommendations without explicitly using that tool. A dedicated tool would improve discoverability.

**Describe the solution**
Add a new MCP tool specifically for cost savings recommendations:

```go
mcp_sdk.AddTool(sdkServer, &mcp_sdk.Tool{
    Name: "get_savings_recommendations",
    Description: "Identifies cost optimization opportunities including resource right-sizing, idle resource cleanup, and reserved instance recommendations. Returns actionable recommendations with estimated savings.",
}, handleSavingsRecommendations)
```

**Benefits**
- Better discoverability for AI agents
- Clearer separation of concerns
- More intuitive API for cost optimization workflows

**Additional context**
This aligns with OpenCost's goal of providing actionable cost insights. Similar tools exist in commercial FinOps platforms.
```

---

### Issue #11: Make MCP Server Opt-In by Default
**File:** `pkg/env/costmodel.go` (Line 379)
**Type:** Security / Configuration
**Effort:** ~2 hours
**Title:** `security(mcp): Change MCP server default to disabled (opt-in)`

```markdown
**Describe the bug**
The MCP server is enabled by default, exposing an additional HTTP endpoint (port 8081) without explicit user consent.

**Location**
`pkg/env/costmodel.go:379`

**Current Code**
```go
func IsMCPServerEnabled() bool {
    return env.GetBool(MCPServerEnabledEnvVar, true)  // Default: enabled
}
```

**Security Concern**
- Users may not expect an additional service running
- Expands attack surface without explicit opt-in
- Against principle of least privilege

**Proposed Solution**
```go
func IsMCPServerEnabled() bool {
    return env.GetBool(MCPServerEnabledEnvVar, false)  // Default: disabled
}
```

**Migration**
- Update documentation to show how to enable MCP
- Add note in CHANGELOG about the default change
```

---

## Timeline Summary

| Week | Phase | Issues | Focus Area |
|------|-------|--------|------------|
| 1-2 | Quick Wins | #1, #2 | Get first PRs merged |
| 3-4 | Stability | #3, #4, #5 | Go idioms, error handling |
| 5-6 | Security | #6, #7, #8 | Security awareness |
| 7 | Resources | #9 | Process lifecycle |
| 8 | Features | #10, #11 | Adding value |

---

## Tips for Success

1. **Start small** - Issues #1 and #2 are intentionally simple to get your first merge
2. **Reference the audit** - Mention you conducted a systematic code audit
3. **Link related issues** - After #3, reference it in #4 and #5 as "related work"
4. **Write tests** - Always include unit tests for your fixes
5. **Update docs** - If behavior changes, update relevant documentation
6. **Be responsive** - Reply to reviewer feedback within 24 hours
7. **Join Slack** - Engage in #opencost channel discussions

---

## Communication Template

When opening issues, use this intro:

> While conducting a code audit of the MCP and Plugin systems, I identified several potential improvements. I'm submitting issues incrementally and am happy to contribute PRs for any that the maintainers find valuable.

This positions you as:
- Proactive (did an audit without being asked)
- Systematic (not random drive-by fixes)
- Collaborative (asking for input before PRing)
