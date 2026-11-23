#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
DOCS_BENCH_DIR="$ROOT_DIR/docs/benchmarks"
CSV_OUT="${1:-$DOCS_BENCH_DIR/results.csv}"
DURATION="${DURATION:-4s}"
CONNS="${CONNS:-16 64 256 512}"
BENCH_DB="${BENCH_DB:-/tmp/leant_bench_suite.db}"
BENCH_SECRET="${BENCH_SECRET:-bench-secret-key}"
TOKEN_FILE="/tmp/leant_bench_token.txt"
GIN_BIN="${GIN_BIN:-}"

mkdir -p "$DOCS_BENCH_DIR"
export PATH="$HOME/.elan/bin:$PATH"

echo "Building Leant benchmark binary..."
(cd "$ROOT_DIR" && lake build bench_leant)
LEANT_BIN="$ROOT_DIR/.lake/build/bin/bench_leant"

rm -f "${BENCH_DB}" "${BENCH_DB}-wal" "${BENCH_DB}-shm" "$TOKEN_FILE"

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

  ADDR="127.0.0.1:${port}" BENCH_DB="$BENCH_DB" BENCH_SECRET="$BENCH_SECRET" TOKEN_OUT="$TOKEN_FILE" \
    "$bin" > "/tmp/bench_${name}.log" 2>&1 &
  local pid=$!
  trap "kill -TERM $pid 2>/dev/null || true; wait $pid 2>/dev/null || true" RETURN

  if ! wait_ready "http://127.0.0.1:${port}/plaintext"; then
    echo "ERROR: $name failed to start"
    cat "/tmp/bench_${name}.log"
    return 1
  fi

  local auth_token=""
  if [ -f "$TOKEN_FILE" ]; then
    auth_token="$(cat "$TOKEN_FILE")"
  fi

  echo "Check /plaintext: $(curl -sS "http://127.0.0.1:${port}/plaintext")"
  echo "Check /json:      $(curl -sS "http://127.0.0.1:${port}/json")"
  echo "Check /db:        $(curl -sS "http://127.0.0.1:${port}/db")"
  echo "Check /authz/42:  $(curl -sS -H "Authorization: Bearer ${auth_token}" "http://127.0.0.1:${port}/authz/42")"

  # Warmup
  wrk -t2 -c16 -d1s "http://127.0.0.1:${port}/plaintext" > /dev/null 2>&1 || true

  for ep in plaintext json db authz; do
    for c in $CONNS; do
      local out url
      if [ "$ep" = "authz" ]; then
        url="http://127.0.0.1:${port}/authz/42"
        out="$(wrk -t2 -c"$c" -d"$DURATION" --latency -H "Authorization: Bearer ${auth_token}" "$url" 2>&1)"
      else
        url="http://127.0.0.1:${port}/${ep}"
        out="$(wrk -t2 -c"$c" -d"$DURATION" --latency "$url" 2>&1)"
      fi
      local rps avg p99 errs rss
      rps="$(echo "$out" | awk '/^Requests\/sec:/ {print $2}')"
      avg="$(echo "$out" | awk '/^\s+Latency/ {print $2; exit}')"
      p99="$(echo "$out" | awk '/^\s+99%/ {print $2; exit}')"
      errs="$(echo "$out" | awk '/Socket errors:/ {s+=$4+$6+$8+$10} /Non-2xx/ {s+=$5} END {print s+0}')"
      rss="$(get_rss_kb "$pid")"
      printf "%-10s /%-9s c=%-4s RPS=%-10s avg=%-9s p99=%-9s err=%-4s rss=%sKB\n" \
        "$name" "$ep" "$c" "$rps" "$avg" "$p99" "$errs" "$rss"
      echo "${name},${ep},${c},${rps},${avg},${p99},${errs},${rss}" >> "$CSV_OUT"
      sleep 0.2
    done
  done

  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  trap - RETURN
}

# Run Leant first so it seeds BENCH_DB and exports the signed Bearer token
bench_server "leant" "$LEANT_BIN" 18082

if [ -n "$GIN_BIN" ] && [ -x "$GIN_BIN" ]; then
  sleep 1
  bench_server "gin" "$GIN_BIN" 18081
else
  echo ""
  echo "Note: Set GIN_BIN=/path/to/gin_bench to include an external Gin comparison."
fi

rm -f "${BENCH_DB}" "${BENCH_DB}-wal" "${BENCH_DB}-shm" "$TOKEN_FILE"
echo ""
echo "Results saved to $CSV_OUT"
