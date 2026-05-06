#!/usr/bin/env bash
# btc_compare.sh — compara dois runs do btc_bench.sh
# Uso: ./btc_compare.sh <label_antes> <label_depois>
# Exemplo: ./btc_compare.sh baseline delta13_io

set -euo pipefail

A="${1:-baseline}"
B="${2:-}"
RESULTS="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/bench_results"

if [[ -z "$B" ]]; then
  echo "Uso: $0 <label_antes> <label_depois>"
  echo ""
  echo "Runs disponíveis:"
  ls "$RESULTS"/ 2>/dev/null || echo "  nenhum ainda — rode ./btc_bench.sh baseline primeiro"
  exit 1
fi

DIR_A="$RESULTS/$A"
DIR_B="$RESULTS/$B"

for d in "$DIR_A" "$DIR_B"; do
  if [[ ! -d "$d" ]]; then
    echo "✗ Não encontrado: $d"
    exit 1
  fi
done

echo ""
echo "════════════════════════════════════════════"
echo "  COMPARAÇÃO: $A  →  $B"
echo "════════════════════════════════════════════"

# ── REGTEST: ms/tx e ms/txin ─────────────────────
echo ""
echo "▶ REGTEST (ms médio por bloco)"
echo ""

parse_regtest() {
  local f="$1/regtest_bench.log"
  [[ -f "$f" ]] || { echo "  (sem log regtest)"; return; }
  awk '
    /Connect [0-9]+ transactions/ {
      match($0, /([0-9]+\.[0-9]+)ms\/tx/, a); sum_tx+=a[1]; n_tx++
    }
    /Verify [0-9]+ txins/ {
      match($0, /([0-9]+\.[0-9]+)ms\/txin/, a); sum_txin+=a[1]; n_txin++
    }
    END {
      printf "%.6f %.6f\n", (n_tx>0 ? sum_tx/n_tx : 0), (n_txin>0 ? sum_txin/n_txin : 0)
    }
  ' "$f"
}

read -r TX_A TXIN_A <<< "$(parse_regtest "$DIR_A")"
read -r TX_B TXIN_B <<< "$(parse_regtest "$DIR_B")"

awk -v a="$TX_A" -v b="$TX_B" -v la="$A" -v lb="$B" 'BEGIN {
  printf "  Connect ms/tx:   %s=%.4fms  %s=%.4fms", la, a, lb, b
  if (a>0 && b>0) {
    pct = (a-b)/a*100
    x   = a/b
    printf "  →  %+.1f%%  (%.2fx %s)\n", pct, x, (b<a?"mais rápido":"mais lento")
  } else print ""
}'

awk -v a="$TXIN_A" -v b="$TXIN_B" -v la="$A" -v lb="$B" 'BEGIN {
  printf "  Verify ms/txin:  %s=%.4fms  %s=%.4fms", la, a, lb, b
  if (a>0 && b>0) {
    pct = (a-b)/a*100
    x   = a/b
    printf "  →  %+.1f%%  (%.2fx %s)\n", pct, x, (b<a?"mais rápido":"mais lento")
  } else print ""
}'

# ── bench_bitcoin CSV ─────────────────────────────
echo ""
echo "▶ MICRO-BENCHMARKS (bench_bitcoin)"
echo ""

CSV_A="$DIR_A/bench.csv"
CSV_B="$DIR_B/bench.csv"

if [[ -f "$CSV_A" && -f "$CSV_B" ]]; then
  # junta pelos nomes dos benchmarks e calcula delta
  awk -F',' -v la="$A" -v lb="$B" '
    NR==FNR {
      # primeiro arquivo (A): guarda ns/op
      if (FNR==1) next  # header
      name=$1; ns=$2
      a_data[name]=ns
      next
    }
    # segundo arquivo (B)
    FNR==1 { next }
    {
      name=$1; ns=$2
      if (name in a_data) {
        na=a_data[name]+0; nb=ns+0
        if (na>0 && nb>0) {
          pct=(na-nb)/na*100
          x=na/nb
          printf "  %-40s  %s=%.1fns  %s=%.1fns  →  %+.1f%% (%.2fx)\n",
            name, la, na, lb, nb, pct, x
        }
      }
    }
  ' "$CSV_A" "$CSV_B"
else
  echo "  (CSV não encontrado — bench_bitcoin pode não ter filtrado nenhum teste)"
fi

# ── UNIT TESTS ────────────────────────────────────
echo ""
echo "▶ UNIT TESTS"
for label in "$A" "$B"; do
  f="$RESULTS/$label/unit_tests.log"
  if [[ -f "$f" ]]; then
    result=$(grep -E "passed|failed" "$f" | tail -1 || echo "  sem resultado")
    printf "  %s: %s\n" "$label" "$result"
  fi
done

# ── ACÚMULO TOTAL ─────────────────────────────────
echo ""
echo "▶ GANHO ACUMULADO (baseline → $B)"

BASE="$RESULTS/baseline/regtest_bench.log"
CURR="$DIR_B/regtest_bench.log"

if [[ -f "$BASE" && -f "$CURR" ]]; then
  read -r _ TXIN_BASE <<< "$(parse_regtest "$RESULTS/baseline")"
  read -r _ TXIN_CURR <<< "$(parse_regtest "$DIR_B")"

  awk -v base="$TXIN_BASE" -v curr="$TXIN_CURR" 'BEGIN {
    if (base>0 && curr>0) {
      x=base/curr
      # IBD ~4h baseline
      ibd_base=4*3600
      ibd_curr=ibd_base/x
      printf "  ms/txin baseline=%.4f  atual=%.4f  →  %.2fx total\n", base, curr, x
      printf "  IBD estimado: baseline=4h00m  atual=%dm%02ds\n",
        int(ibd_curr/60), int(ibd_curr)%60
    } else {
      print "  (dados insuficientes)"
    }
  }'
fi

echo ""
echo "════════════════════════════════════════════"
echo " Próximas intervenções disponíveis:"
echo "   δ¹³  I/O ordering  →  ./btc_bench.sh delta13_io"
echo "   δ²⁰⁻²²  Schnorr batch →  ./btc_bench.sh schnorr_batch"
echo "   θ*   FlowController  →  ./btc_bench.sh theta_flow"
echo ""
echo " Comparar próxima:"
echo "   ./btc_compare.sh $B <próximo_label>"
echo "════════════════════════════════════════════"