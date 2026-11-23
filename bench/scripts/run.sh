#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GIN_DIR="$ROOT_DIR/bench/baselines/gin"
RESULTS_DIR="$ROOT_DIR/bench/results"
CSV_OUT="${1:-$RESULTS_DIR/http-benchmarks.csv}"
DURATION="${DURATION:-5s}"
CONNS="${CONNS:-16 64 256 512}"

mkdir -p "$RESULTS_DIR"
export PATH="$HOME/.elan/bin:$PATH"

echo "Building Leant benchmark binary..."
(cd "$ROOT_DIR" && lake build bench_leant)

echo "Building Gin baseline binary..."
(cd "$GIN_DIR" && [ -f go.mod ] || go mod init gin_baseline && go get github.com/gin-gonic/gin@latest && go build -o gin_baseline .)

LEANT_BIN="$ROOT_DIR/.lake/build/bin/bench_leant"
GIN_BIN="$GIN_DIR/gin_baseline"

echo "server,endpoint,connections,rps,avg_latency,p99_latency,errors,rss_kb" > "$CSV_OUT"

get_rss_kb() {
  local pid="$1"
  if [ -r "/proc/$pid/status" ]; then
    awk '/^VmRSS:/ {print $2}' "/proc/$pid/status"
  else
    echo "0"
  fi
}

wait_ready() {
  local url="$1"
  for _ in $(seq 1 50); do
    if curl -sf "$url" > /dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

bench_server() {
  local name="$1"
  local bin="$2"
  local port="$3"

  echo ""
  echo "============================================================"
  echo "Benchmarking: $name (127.0.0.1:$port)"
  echo "============================================================"

  ADDR="127.0.0.1:${port}" "$bin" > "/tmp/bench_${name}.log" 2>&1 &
  local pid=$!
  trap "kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true" RETURN

  if ! wait_ready "http://127.0.0.1:${port}/plaintext"; then
    echo "ERROR: $name failed to start"
    cat "/tmp/bench_${name}.log"
    return 1
  fi

  echo "Check /plaintext: $(curl -sS http://127.0.0.1:${port}/plaintext)"
  echo "Check /json:      $(curl -sS http://127.0.0.1:${port}/json)"

  # Warmup
  wrk -t2 -c16 -d2s "http://127.0.0.1:${port}/plaintext" > /dev/null 2>&1 || true

  for ep in plaintext json; do
    for c in $CONNS; do
      local out
      out="$(wrk -t2 -c"$c" -d"$DURATION" --latency "http://127.0.0.1:${port}/${ep}" 2>&1)"
      local rps avg p99 errs rss
      rps="$(echo "$out" | awk '/^Requests\/sec:/ {print $2}')"
      avg="$(echo "$out" | awk '/^\s+Latency/ {print $2; exit}')"
      p99="$(echo "$out" | awk '/^\s+99%/ {print $2; exit}')"
      errs="$(echo "$out" | awk '/Socket errors:/ {s+=$4+$6+$8+$10} /Non-2xx/ {s+=$5} END {print s+0}')"
      rss="$(get_rss_kb "$pid")"
      printf "%-12s /%-9s c=%-4s RPS=%-10s avg=%-9s p99=%-9s err=%-4s rss=%sKB\n" \
        "$name" "$ep" "$c" "$rps" "$avg" "$p99" "$errs" "$rss"
      echo "${name},${ep},${c},${rps},${avg},${p99},${errs},${rss}" >> "$CSV_OUT"
    done
  done

  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  trap - RETURN
}

bench_server "gin" "$GIN_BIN" 18081
sleep 1
bench_server "leant" "$LEANT_BIN" 18082

echo ""
echo "Results saved to $CSV_OUT"
