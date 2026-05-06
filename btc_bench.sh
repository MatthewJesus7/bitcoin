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
BITCOIND="$BUILD_DIR/bin/bitcoind"
BENCH_BIN="$BUILD_DIR/bin/bench_bitcoin"
TEST_BIN="$BUILD_DIR/bin/test_bitcoin"

for bin in "$BITCOIND" "$BENCH_BIN"; do
  if [[ ! -x "$bin" ]]; then
    echo "✗ $(basename "$bin") não encontrado — rode ./btc_setup.sh primeiro"
    exit 1
  fi
done

echo ""
echo "▶ [0/3] BINÁRIOS"
for f in "$BITCOIND" "$BENCH_BIN" "$TEST_BIN"; do
  [[ -x "$f" ]] && printf "   ✓ %-30s %s\n" "$(basename "$f")" "$(du -h "$f" | cut -f1)"
done

# ── UNIT TESTS ───────────────────────────────────
echo ""
echo "▶ [1/3] UNIT TESTS"
UNIT_LOG="$OUT/unit_tests.log"

ctest --test-dir "$BUILD_DIR" \
  --output-on-failure \
  -R "validation_tests|coins_tests|script_tests|checkqueue_tests" \
  2>&1 | tee "$UNIT_LOG" | grep -E "passed|failed|Test #" || true

echo "   → $UNIT_LOG"

# ── MICRO-BENCHMARKS ─────────────────────────────
echo ""
echo "▶ [2/3] MICRO-BENCHMARKS"

if [[ ! -x "$BENCH_BIN" ]]; then
  echo "   ✗ bench_bitcoin não encontrado"
else
  FILTERS="ConnectBlockAllEcdsa|ConnectBlockAllSchnorr|ConnectBlockMixedEcdsaSchnorr|VerifyScriptP2TR_KeyPath|VerifyScriptP2TR_ScriptPath|VerifyScriptP2WPKH|CCoinsCaching|CCheckQueueSpeedPrevectorJob|SignTransactionECDSA|SignTransactionSchnorr"

  "$BENCH_BIN" \
    -filter="$FILTERS" \
    -output-csv="$OUT/bench.csv" \
    -min-time=3000 \
    2>&1 | tee "$OUT/bench.log"

  echo "   → $OUT/bench.csv"
fi

# ── REGTEST ──────────────────────────────────────
echo ""
echo "▶ [3/3] REGTEST (50 blocos)"

CLI="$BUILD_DIR/bin/bitcoin-cli"
DATADIR="/tmp/btc_bench_regtest_$$"

# limpa processo órfão de run anterior na mesma porta
echo "   verificando porta 19445..."
if lsof -ti tcp:19445 2>/dev/null | xargs kill -9 2>/dev/null; then
  echo "   ✓ processo órfão eliminado na porta 19445"
  sleep 1
else
  echo "   ✓ porta 19445 livre"
fi

cleanup() {
  echo "   [cleanup] enviando stop ao bitcoind..."
  "$CLI" -regtest -datadir="$DATADIR" -rpcport=19445 stop 2>/dev/null || true

  echo "   [cleanup] aguardando processo encerrar..."
  local waited=0
  while "$CLI" -regtest -datadir="$DATADIR" -rpcport=19445 ping 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
    if (( waited >= 15 )); then
      echo "   [cleanup] timeout — forçando kill na porta 19445"
      lsof -ti tcp:19445 2>/dev/null | xargs kill -9 2>/dev/null || true
      break
    fi
  done

  echo "   [cleanup] removendo datadir $DATADIR"
  rm -rf "$DATADIR"
}
trap cleanup EXIT

mkdir -p "$DATADIR"

echo "   iniciando bitcoind (regtest, rpcport=19445)..."
"$BITCOIND" \
  -regtest \
  -datadir="$DATADIR" \
  -debug=bench \
  -daemon \
  -listen=0 \
  -port=19444 \
  -rpcport=19445

echo "   aguardando bitcoind estar pronto..."
if ! "$CLI" -regtest -datadir="$DATADIR" -rpcport=19445 -rpcwait getblockcount > /dev/null 2>&1; then
  echo "   ✗ bitcoind não respondeu — abortando"
  echo "   debug.log:"
  cat "$DATADIR/regtest/debug.log" 2>/dev/null || echo "   (sem debug.log)"
  exit 1
fi
echo "   ✓ bitcoind pronto"

# wallet opcional — só tenta se o build tiver suporte
if "$CLI" -regtest -datadir="$DATADIR" -rpcport=19445 createwallet "bench" > /dev/null 2>&1; then
  echo "   ✓ wallet 'bench' criada"
  REGTEST_ADDR=$("$CLI" -regtest -datadir="$DATADIR" -rpcport=19445 getnewaddress)
  echo "   minerando 5000 blocos para $REGTEST_ADDR..."
  "$CLI" -regtest -datadir="$DATADIR" -rpcport=19445 generatetoaddress 5000 "$REGTEST_ADDR" > /dev/null
else
  echo "   ℹ wallet support ausente — minerando via descriptor raw(51)"
  "$CLI" -regtest -datadir="$DATADIR" -rpcport=19445 generatetodescriptor 5000 "raw(51)" > /dev/null
fi
echo "   ✓ 5000 blocos minerados"

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