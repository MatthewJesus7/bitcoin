#!/usr/bin/env bash
# btc_bench.sh — roda benchmarks (não recompila — use btc_setup.sh pra isso)
# Uso: ./btc_bench.sh [label]

set -euo pipefail

LABEL="${1:-$(date +%Y%m%d_%H%M%S)}"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
BUILD_DIR="$REPO_ROOT/build"
RESULTS_DIR="$REPO_ROOT/bench_results"
OUT="$RESULTS_DIR/$LABEL"

mkdir -p "$OUT"

echo "════════════════════════════════════════════"
echo " btc_bench.sh  —  label: $LABEL"
echo " $(date)"
echo " commit: $(git rev-parse --short HEAD 2>/dev/null || echo 'n/a')"
echo "════════════════════════════════════════════"

# ── VERIFICA BUILD ───────────────────────────────
BITCOIND="$BUILD_DIR/src/bitcoind"
BENCH_BIN="$BUILD_DIR/src/bench/bench_bitcoin"
TEST_BIN="$BUILD_DIR/src/test/test_bitcoin"

if [[ ! -x "$BITCOIND" ]]; then
  echo "✗ bitcoind não encontrado — rode ./btc_setup.sh primeiro"
  exit 1
fi

# Recompila só o que mudou (incremental)
echo ""
echo "▶ [1/4] BUILD INCREMENTAL"
cmake --build "$BUILD_DIR" -j1 2>&1 | grep -E "^\[|error:|Linking" | \
  awk '/^\[/{printf "\r  %s", $0; fflush()} /error:/{print "\n  ✗ "$0}'
echo ""
echo "   ✓ build ok"

# ── UNIT TESTS ───────────────────────────────────
echo ""
echo "▶ [2/4] UNIT TESTS"
UNIT_LOG="$OUT/unit_tests.log"

ctest --test-dir "$BUILD_DIR" \
  --output-on-failure \
  -R "validation_tests|coins_tests|script_tests|checkqueue_tests" \
  2>&1 | tee "$UNIT_LOG" | grep -E "passed|failed|Test #"

echo "   → $UNIT_LOG"

# ── MICRO-BENCHMARKS ─────────────────────────────
echo ""
echo "▶ [3/4] MICRO-BENCHMARKS"

if [[ ! -x "$BENCH_BIN" ]]; then
  echo "   ✗ bench_bitcoin não encontrado"
else
  FILTERS="CoinsCaching|UTXOLookup|VerifyScript|CheckInputScripts|Schnorr|CheckQueue|ConnectBlock|Coins|Script"

  "$BENCH_BIN" \
    -filter="$FILTERS" \
    -output-csv="$OUT/bench.csv" \
    -min-time=3000 \
    2>&1 | tee "$OUT/bench.log"

  echo "   → $OUT/bench.csv"
fi

# ── REGTEST ──────────────────────────────────────
echo ""
echo "▶ [4/4] REGTEST (50 blocos)"

CLI="$BUILD_DIR/src/bitcoin-cli"
DATADIR="/tmp/btc_bench_regtest_$$"

cleanup() {
  "$CLI" -regtest -datadir="$DATADIR" stop 2>/dev/null || true
  sleep 2
  rm -rf "$DATADIR"
}
trap cleanup EXIT

mkdir -p "$DATADIR"

"$BITCOIND" \
  -regtest \
  -datadir="$DATADIR" \
  -debug=bench \
  -daemon \
  -listen=0 \
  -port=19444 \
  -rpcport=19445

echo "   aguardando bitcoind..."
sleep 4

ADDR=$("$CLI" -regtest -datadir="$DATADIR" getnewaddress)
"$CLI" -regtest -datadir="$DATADIR" generatetoaddress 50 "$ADDR" > /dev/null

REGTEST_OUT="$OUT/regtest_bench.log"
grep -E "Connect [0-9]+ transactions|Verify [0-9]+ txins|Sanity checks|Fork checks" \
  "$DATADIR/regtest/debug.log" > "$REGTEST_OUT" || true

echo ""
echo "   ┌─ Resumo regtest:"
awk '
  /Connect [0-9]+ transactions/ {
    match($0, /([0-9]+\.[0-9]+)ms\/tx/, a); sum_tx+=a[1]; n_tx++
  }
  /Verify [0-9]+ txins/ {
    match($0, /([0-9]+\.[0-9]+)ms\/txin/, a); sum_txin+=a[1]; n_txin++
  }
  END {
    if (n_tx>0)   printf "   │  Connect: %.4f ms/tx   (%d blocos)\n", sum_tx/n_tx, n_tx
    if (n_txin>0) printf "   │  Verify:  %.4f ms/txin (%d blocos)\n", sum_txin/n_txin, n_txin
  }
' "$REGTEST_OUT"
echo "   └─ $REGTEST_OUT"

# ── SUMÁRIO ──────────────────────────────────────
echo ""
echo "════════════════════════════════════════════"
echo " RESULTADOS: $OUT/"
ls -lh "$OUT/"
echo ""
echo " Comparar:"
echo "   ./btc_compare.sh baseline $LABEL"
echo "════════════════════════════════════════════"