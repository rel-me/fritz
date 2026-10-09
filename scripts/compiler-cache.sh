#!/bin/bash
# Configure the same environment before reuse checks and compilation.
configure_compiler_cache() {
  local sccache_binary
  if ! sccache_binary="$(mise which sccache)"; then
    echo 'error: run mise trust mise.toml && mise install before building Fritz' >&2
    return 1
  fi
  export RUSTC_WRAPPER="$sccache_binary"
  export SCCACHE_DIR="$FRITZ_BUILD_ROOT/compiler-cache/rust"
  export SCCACHE_CACHE_SIZE=20G
  export SCCACHE_SERVER_UDS="$FRITZ_BUILD_ROOT/compiler-cache/sccache-0.18.0.sock"
  export FRITZ_METAL_CACHE_ROOT="$FRITZ_BUILD_ROOT/compiler-cache/metal/v1"
  export PATH="$PWD/scripts/native-cache-bin:$PATH"
  mkdir -p "$SCCACHE_DIR" "$FRITZ_METAL_CACHE_ROOT"
  xcode_cache_settings=(
    COMPILATION_CACHE_ENABLE_CACHING=YES
    "COMPILATION_CACHE_CAS_PATH=$FRITZ_BUILD_ROOT/compiler-cache/xcode"
  )
}

start_compiler_cache() {
  # Delay daemon startup until an app actually needs compilation.
  /usr/bin/lockf -k "$FRITZ_BUILD_ROOT/compiler-cache/server-start.lock" \
    "$RUSTC_WRAPPER" "$(command -v rustc)" -vV >/dev/null
}
