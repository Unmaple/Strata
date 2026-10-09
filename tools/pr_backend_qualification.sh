#!/usr/bin/env bash
# Compile qualification only. Hosted runners have no matching GPU; no runtime pass is implied.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends cmake ninja-build build-essential git python3 libnuma-dev > /logs/packages.log 2>&1
git config --global --add safe.directory /source
cd /source
git rev-parse HEAD > /logs/head.txt
if [[ $BACKEND == sycl ]]; then
  if ! find /opt/intel/oneapi -path '*/include/dpct/dpct.hpp' -print -quit | grep -q .; then
    apt-get install -y -qq --no-install-recommends intel-oneapi-dpcpp-ct >> /logs/packages.log 2>&1
  fi
  set +u
  echo 'Initializing oneAPI environment (force handles preinitialized container env)'
  source /opt/intel/oneapi/setvars.sh --force > /logs/setvars.log 2>&1 || { cat /logs/setvars.log; exit 3; }
  set -u
  icpx --version | tee /logs/compiler.txt
else
  export PATH=/opt/rocm/bin:/opt/rocm/llvm/bin:$PATH
  /opt/rocm/llvm/bin/clang++ --version > /logs/compiler.txt
fi
build_one() {
  local source=$1 label=$2
  echo "Configuring $label for $BACKEND"
  if [[ $BACKEND == sycl ]]; then
    cmake -S "$source/sycl" -B "/tmp/build-$label" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icpx \
      -DSTRATA_SYCL_AOT="" > "/logs/$label-config.log" 2>&1 || return $?
  else
    cmake -S "$source" -B "/tmp/build-$label" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DSTRATA_ENABLE_HIP=ON -DSTRATA_BUILD_TESTS=OFF \
      -DCMAKE_HIP_COMPILER=/opt/rocm/llvm/bin/clang++ -DCMAKE_HIP_ARCHITECTURES=gfx1100 \
      > "/logs/$label-config.log" 2>&1 || return $?
  fi
  echo "Compiling $label for $BACKEND"
  cmake --build "/tmp/build-$label" --target strata -j 2 > "/logs/$label-build.log" 2>&1
}
set +e
build_one /source candidate
candidate=$?
set -e
printf '%s\n' "$candidate" > /logs/candidate-exit.txt
if [[ $candidate != 0 ]]; then
  git worktree add --detach /tmp/upstream-baseline fb58e0dbc8399662c0e47c76578c6e878b14f6cf > /logs/baseline-checkout.log 2>&1
  set +e
  build_one /tmp/upstream-baseline baseline
  baseline=$?
  set -e
  printf '%s\n' "$baseline" > /logs/baseline-exit.txt
  echo "Candidate exit=$candidate baseline exit=$baseline"
  for label in candidate baseline; do
    echo "=== $label errors ==="
    grep -n -E -B 2 -A 3 'error:|CMake Error|FAILED:' "/logs/$label-config.log" "/logs/$label-build.log" || true
  done
  tail -60 /logs/candidate-config.log
  [[ ! -f /logs/candidate-build.log ]] || tail -80 /logs/candidate-build.log
  exit "$candidate"
fi
cp /tmp/build-candidate/CMakeCache.txt /logs/CMakeCache.txt
echo 'Complete engine compiled; matching-backend GPU runtime not tested.' > /logs/RESULT.txt
