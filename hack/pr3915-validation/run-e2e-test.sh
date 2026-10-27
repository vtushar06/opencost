#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== PR #3915 E2E Validation Test ==="
echo ""

# Check prerequisites
echo "Checking prerequisites..."
command -v kind >/dev/null 2>&1 || { echo "ERROR: kind is not installed"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl is not installed"; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker is not installed"; exit 1; }

echo "✓ Prerequisites OK"
echo ""

# Build OpenCost image
echo "Building OpenCost docker image..."
cd ../..
docker build -t opencost-pr3915:local -f Dockerfile .
echo "✓ OpenCost image built"
echo ""

cd "$SCRIPT_DIR"

# Create kind cluster
echo "Creating kind cluster..."
if kind get clusters | grep -q "^opencost-pr3915$"; then
  echo "Cluster already exists, deleting..."
  kind delete cluster --name opencost-pr3915
fi
kind create cluster --config kind-config.yaml --wait 120s
echo "✓ Kind cluster created"
echo ""

# Load image into kind
echo "Loading OpenCost image into kind..."
kind load docker-image opencost-pr3915:local --name opencost-pr3915
echo "✓ Image loaded"
echo ""

# Apply manifests
echo "Applying Kubernetes manifests..."
kubectl apply -f prometheus-config.yaml
kubectl apply -f vllm-simulator.yaml
kubectl apply -f opencost-deployment.yaml
echo "✓ Manifests applied"
echo ""

# Wait for pods
echo "Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod -l app=prometheus -n monitoring --timeout=120s
kubectl wait --for=condition=ready pod -l app=llama-model-server -n llm-d --timeout=120s
kubectl wait --for=condition=ready pod -l app=qwen-model-server -n llm-d --timeout=120s
kubectl wait --for=condition=ready pod -l app=opencost -n opencost --timeout=120s
echo "✓ All pods ready"
echo ""

# Get pod UIDs
echo "Fetching pod UIDs..."
LLAMA_POD_UID=$(kubectl get pod -n llm-d -l app=llama-model-server -o jsonpath='{.items[0].metadata.uid}')
QWEN_POD_UID=$(kubectl get pod -n llm-d -l app=qwen-model-server -o jsonpath='{.items[0].metadata.uid}')
echo "Llama pod UID: $LLAMA_POD_UID"
echo "Qwen pod UID: $QWEN_POD_UID"
echo ""

# Verify Prometheus is scraping
echo "Verifying Prometheus scraping..."
sleep 30
echo "Checking vllm:kv_cache_usage_perc..."
CACHE_METRICS=$(kubectl exec -n monitoring deployment/prometheus -- wget -qO- 'http://localhost:9090/api/v1/query?query=vllm:kv_cache_usage_perc' | grep -o '"result":\[.*\]')
if [ -z "$CACHE_METRICS" ] || [ "$CACHE_METRICS" = '"result":[]' ]; then
  echo "WARNING: No vllm:kv_cache_usage_perc metrics found in Prometheus"
else
  echo "✓ vLLM metrics found in Prometheus"
fi
echo ""

echo "Checking vllm:num_requests_waiting..."
QUEUE_METRICS=$(kubectl exec -n monitoring deployment/prometheus -- wget -qO- 'http://localhost:9090/api/v1/query?query=vllm:num_requests_waiting' | grep -o '"result":\[.*\]')
if [ -z "$QUEUE_METRICS" ] || [ "$QUEUE_METRICS" = '"result":[]' ]; then
  echo "WARNING: No vllm:num_requests_waiting metrics found in Prometheus"
else
  echo "✓ vLLM queue metrics found in Prometheus"
fi
echo ""

# Check if metrics have pod_uid label
echo "Verifying pod_uid labels on vLLM metrics..."
POD_UID_CHECK=$(kubectl exec -n monitoring deployment/prometheus -- wget -qO- 'http://localhost:9090/api/v1/query?query=vllm:kv_cache_usage_perc' | grep -o 'pod_uid' | head -1)
if [ -z "$POD_UID_CHECK" ]; then
  echo "WARNING: pod_uid label NOT found on vLLM metrics - saturation metrics will not work!"
  echo "This is expected if the relabel config is not correctly applied."
else
  echo "✓ pod_uid labels present on vLLM metrics"
fi
echo ""

# Generate some load (simulated requests)
echo "Generating simulated load..."
LLAMA_SERVICE_IP=$(kubectl get svc llama-model-server -n llm-d -o jsonpath='{.spec.clusterIP}')

# Run load in background
kubectl run load-generator --image=curlimages/curl:latest --restart=Never -n llm-d -- sh -c "
for i in \$(seq 1 20); do
  curl -s -X POST http://$LLAMA_SERVICE_IP:8000/v1/completions \
    -H 'Content-Type: application/json' \
    -d '{\"model\": \"Llama-3.1-8B\", \"prompt\": \"Write a haiku about clouds\", \"max_tokens\": 50}' >/dev/null 2>&1
  sleep 1
done
" &

sleep 10
echo "✓ Load generation started"
echo ""

# Wait a bit for metrics to accumulate
echo "Waiting for metrics to accumulate (60s)..."
sleep 60
echo ""

# Query OpenCost for InferenceEngine data
echo "Querying OpenCost KubeModel for InferenceEngine data..."
OPENCOST_POD=$(kubectl get pod -n opencost -l app=opencost -o jsonpath='{.items[0].metadata.name}')

# Try to query the API (note: may not be implemented in compute layer yet)
echo "Attempting to query saturation metrics from OpenCost..."
kubectl exec -n opencost "$OPENCOST_POD" -- wget -qO- 'http://localhost:9003/metrics' | grep -E 'inference_engine|kv_cache|queue_depth|running_requests' || echo "No inference_engine metrics found in OpenCost /metrics"
echo ""

# Query Prometheus for the raw vLLM metrics
echo "=== Raw Prometheus Metrics ==="
echo ""
echo "vllm:kv_cache_usage_perc:"
kubectl exec -n monitoring deployment/prometheus -- wget -qO- 'http://localhost:9090/api/v1/query?query=vllm:kv_cache_usage_perc' | python3 -m json.tool || echo "Query failed"
echo ""

echo "vllm:num_requests_waiting:"
kubectl exec -n monitoring deployment/prometheus -- wget -qO- 'http://localhost:9090/api/v1/query?query=vllm:num_requests_waiting' | python3 -m json.tool || echo "Query failed"
echo ""

echo "vllm:num_requests_running:"
kubectl exec -n monitoring deployment/prometheus -- wget -qO- 'http://localhost:9090/api/v1/query?query=vllm:num_requests_running' | python3 -m json.tool || echo "Query failed"
echo ""

echo "vllm:num_preemptions_total:"
kubectl exec -n monitoring deployment/prometheus -- wget -qO- 'http://localhost:9090/api/v1/query?query=vllm:num_preemptions_total' | python3 -m json.tool || echo "Query failed"
echo ""

# Cleanup
echo "Cleaning up load generator..."
kubectl delete pod load-generator -n llm-d --ignore-not-found=true
echo ""

echo "=== Test Complete ==="
echo ""
echo "Cluster is still running. Access points:"
echo "  Prometheus: http://localhost:9090"
echo "  OpenCost:   http://localhost:9003"
echo "  vLLM Sim:   http://localhost:8080"
echo ""
echo "To clean up: kind delete cluster --name opencost-pr3915"
