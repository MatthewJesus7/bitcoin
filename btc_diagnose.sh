#!/usr/bin/env bash
# btc_diagnose.sh — diagnóstico universal do ambiente
# Uso: ./btc_diagnose.sh

echo "════════════════════════════════════════════"
echo " DIAGNÓSTICO DO AMBIENTE — $(date)"
echo "════════════════════════════════════════════"

# ── HARDWARE ─────────────────────────────────────
echo ""
echo "▶ HARDWARE"
echo "  CPU:      $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
echo "  Cores:    $(nproc) lógicos / $(grep 'cpu cores' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs) físicos"
echo "  Arch:     $(uname -m)"
echo "  RAM:      $(free -h | awk '/^Mem/{print $2}') total / $(free -h | awk '/^Mem/{print $7}') disponível"
echo "  Disk:     $(df -h . | awk 'NR==2{print $4}') livres em $(df -h . | awk 'NR==2{print $6}')"
echo "  Disk tipo:$(cat /sys/block/$(df . | awk 'NR==2{print $1}' | sed 's|/dev/||' | sed 's/[0-9]*$//')/queue/rotational 2>/dev/null | awk '{print ($1==1?"HDD":"SSD/NVMe")}' || echo "  desconhecido")"

# ── OS ───────────────────────────────────────────
echo ""
echo "▶ OS"
echo "  $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
echo "  Kernel: $(uname -r)"

# ── COMPILADOR ───────────────────────────────────
echo ""
echo "▶ COMPILADORES"
for bin in gcc g++ clang clang++ c++; do
  if command -v "$bin" &>/dev/null; then
    printf "  ✓ %-10s %s\n" "$bin" "$($bin --version 2>&1 | head -1)"
  else
    printf "  ✗ %-10s não encontrado\n" "$bin"
  fi
done

echo "  C++ padrão: $(c++ -dumpversion 2>/dev/null || echo '?')"

# ── CMAKE ────────────────────────────────────────
echo ""
echo "▶ CMAKE"
if command -v cmake &>/dev/null; then
  echo "  ✓ $(cmake --version | head -1)"
else
  echo "  ✗ cmake não encontrado"
fi

# ── DEPENDÊNCIAS ─────────────────────────────────
echo ""
echo "▶ DEPENDÊNCIAS"

check_pkg() {
  local name="$1"
  local pkg="$2"
  if pkg-config --exists "$pkg" 2>/dev/null; then
    printf "  ✓ %-20s %s\n" "$name" "$(pkg-config --modversion "$pkg" 2>/dev/null || echo 'ok')"
  else
    printf "  ✗ %-20s FALTA  →  sudo apt install %s\n" "$name" "$name"
  fi
}

check_apt() {
  local name="$1"
  local pkg="${2:-$1}"
  if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
    printf "  ✓ %-20s %s\n" "$name" "$(dpkg -l "$pkg" 2>/dev/null | awk '/^ii/{print $3}')"
  else
    printf "  ✗ %-20s FALTA  →  sudo apt install %s\n" "$name" "$pkg"
  fi
}

check_pkg  "libevent"      "libevent"
check_pkg  "sqlite3"       "sqlite3"
check_pkg  "libzmq"        "libzmq"
check_pkg  "miniupnpc"     "miniupnpc"
check_apt  "libboost-dev"  "libboost-dev"
check_apt  "libdb5.3++"    "libdb5.3++-dev"
check_apt  "systemtap-sdt" "systemtap-sdt-dev"

# ── RECURSOS DE CPU ──────────────────────────────
echo ""
echo "▶ FEATURES CPU (relevantes para secp256k1)"
for flag in sse2 sse4_1 avx avx2 bmi2 adx; do
  grep -q "$flag" /proc/cpuinfo \
    && printf "  ✓ %s\n" "$flag" \
    || printf "  ✗ %s (não suportado)\n" "$flag"
done

# ── BUILD DIR ────────────────────────────────────
echo ""
echo "▶ BUILD DIR"
BUILD="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/build"
if [[ -d "$BUILD" ]]; then
  echo "  exists: $BUILD"
  echo "  tamanho: $(du -sh "$BUILD" 2>/dev/null | cut -f1)"
  if [[ -f "$BUILD/CMakeCache.txt" ]]; then
    echo "  cmake configurado: sim"
    grep -E "CMAKE_BUILD_TYPE|BUILD_BENCH|BUILD_TESTS" "$BUILD/CMakeCache.txt" | \
      awk -F= '{printf "    %s = %s\n", $1, $2}'
  else
    echo "  cmake configurado: NÃO"
  fi
else
  echo "  não existe ainda"
fi

echo ""
echo "════════════════════════════════════════════"
echo " Próximo passo: ./btc_setup.sh"
echo "════════════════════════════════════════════"