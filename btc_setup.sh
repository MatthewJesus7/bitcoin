#!/usr/bin/env bash
# btc_setup.sh — Celeron 1007U / HDD / 6GB RAM
set -euo pipefail

REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
BUILD="$REPO/build"

echo "════════════════════════════════════════════"
echo " btc_setup.sh — Celeron 1007U"
echo "════════════════════════════════════════════"

# CPU real: SSE2 + SSE4.1 apenas — sem AVX, AVX2, BMI2, ADX
# -march=ivybridge habilita AVX por padrão → -mno-avx desliga explicitamente
# 2 cores, HDD, ~2GB RAM → 1 job (linker ~1.5GB)
# secp256k1 window=11 → balanço RAM/velocidade para 2GB

JOBS=1

echo "  jobs:       $JOBS (RAM limitada)"
echo "  arch:       ivybridge + mno-avx (SSE4.1 only)"
echo "  secp256k1:  window=11, testes OFF"
echo "  IPC:        OFF"
echo "  LTO:        OFF"

rm -rf "$BUILD"

cmake -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=gcc \
  -DCMAKE_CXX_COMPILER=g++ \
  -DCMAKE_C_FLAGS="-O2 -march=ivybridge -msse4.1 -mno-avx -fno-plt" \
  -DCMAKE_CXX_FLAGS="-O2 -march=ivybridge -msse4.1 -mno-avx -fno-plt -fno-omit-frame-pointer" \
  -DCMAKE_EXE_LINKER_FLAGS="-Wl,--as-needed" \
  -DBUILD_BENCH=ON \
  -DBUILD_TESTS=ON \
  -DENABLE_WALLET=OFF \
  -DENABLE_IPC=OFF \
  -DWITH_MINIUPNPC=OFF \
  -DWITH_ZMQ=OFF \
  -DWITH_USDT=OFF \
  -DWERROR=OFF \
  -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF \
  -DSECP256K1_ECMULT_WINDOW_SIZE=11 \
  -DSECP256K1_BUILD_TESTS=OFF \
  -S "$REPO" \
  2>&1 | tee /tmp/btc_cmake.log | grep -E "error:|warning:|Configuring done|Build files"

echo "  ✓ cmake configurado (log completo: /tmp/btc_cmake.log)"
echo ""
echo "▶ BUILD — 30-60 min no Celeron HDD"
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
for bin in bitcoind bitcoin-cli bench_bitcoin test_bitcoin; do
  f=""
  for path in \
    "$BUILD/bin/$bin" \
    "$BUILD/src/$bin" \
    "$BUILD/src/bench/$bin" \
    "$BUILD/src/test/$bin"; do
    [[ -x "$path" ]] && f="$path" && break
  done
  if [[ -n "$f" ]]; then
    printf "  ✓ %-35s %s\n" "$bin" "$(du -h "$f" | cut -f1)"
  else
    printf "  ✗ %-35s não encontrado\n" "$bin"
  fi
done

echo ""
echo "════════════════════════════════════════════"
echo " Próximo: ./btc_bench.sh baseline"
echo "════════════════════════════════════════════"