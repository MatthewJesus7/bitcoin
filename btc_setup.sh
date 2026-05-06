#!/usr/bin/env bash
# btc_setup.sh — configurado para Celeron 1007U / Ivy Bridge / HDD / 6GB RAM
set -euo pipefail

REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
BUILD="$REPO/build"

echo "════════════════════════════════════════════"
echo " btc_setup.sh — Celeron 1007U / Ivy Bridge"
echo "════════════════════════════════════════════"

# Ivy Bridge: SSE4.1 sim, AVX não → window=11
# 2 cores, HDD, ~2GB RAM livre → 1 job (linker come RAM)
# gcc 11, sem clang

JOBS=1   # linker precisa de ~1.5GB por job — com 2.2GB livres, 1 é seguro

echo "  jobs de compilação: $JOBS (HDD + RAM limitada)"
echo "  secp256k1 window:   11 (SSE4.1, sem AVX)"
echo "  compilador:         gcc 11"
echo "  LTO:                OFF (RAM insuficiente)"
echo "  arch target:        -march=ivybridge (Celeron 1007U)"

rm -rf "$BUILD"

cmake -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=gcc \
  -DCMAKE_CXX_COMPILER=g++ \
  -DCMAKE_C_FLAGS="-O2 -march=ivybridge -mtune=ivybridge -msse4.1 -fno-plt" \
  -DCMAKE_CXX_FLAGS="-O2 -march=ivybridge -mtune=ivybridge -msse4.1 -fno-plt -fno-omit-frame-pointer" \
  -DCMAKE_EXE_LINKER_FLAGS="-Wl,--as-needed" \
  -DBUILD_BENCH=ON \
  -DBUILD_TESTS=ON \
  -DENABLE_WALLET=OFF \
  -DWITH_MINIUPNPC=OFF \
  -DWITH_ZMQ=OFF \
  -DWITH_USDT=OFF \
  -DWERROR=OFF \
  -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF \
  -S "$REPO" \
  2>&1 | grep -E "error:|Configuring done|Build files" | head -20

echo "  ✓ cmake configurado"
echo ""
echo "▶ BUILD — pode demorar 30-60 min no Celeron HDD"
echo "  acompanhe: tail -f /tmp/btc_build.log"
echo ""

START=$(date +%s)

cmake --build "$BUILD" -j"$JOBS" 2>&1 | tee /tmp/btc_build.log | \
  grep -E "^\[|error:" | \
  awk '/^\[/{printf "\r  %s", $0; fflush()} /error:/{print "\n  ✗ "$0}'

END=$(date +%s)
echo ""
echo "  ✓ $(( (END-START)/60 ))m$(( (END-START)%60 ))s"

echo ""
echo "▶ BINÁRIOS"
for bin in bitcoind bitcoin-cli bench/bench_bitcoin test/test_bitcoin; do
  f="$BUILD/src/$bin"
  [[ -x "$f" ]] \
    && printf "  ✓ %-35s %s\n" "$bin" "$(du -h "$f" | cut -f1)" \
    || printf "  ✗ %-35s não gerado\n" "$bin"
done

echo ""
echo "════════════════════════════════════════════"
echo " Próximo: ./btc_bench.sh baseline"
echo "════════════════════════════════════════════"