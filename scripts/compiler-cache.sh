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
  # macOS Unix sockets have a short path limit, even when cache roots are long.
  local socket_directory root_hash
  socket_directory="/tmp/fritz-sc-$(id -u)"
  mkdir -m 700 "$socket_directory" 2>/dev/null || {
    if [[ ! -d "$socket_directory" || -L "$socket_directory" || ! -O "$socket_directory" ]]; then
      echo "error: sccache socket directory must be owned by the current user: $socket_directory" >&2
      return 1
    fi
  }
  chmod 700 "$socket_directory"
  root_hash="$(printf '%s' "$FRITZ_BUILD_ROOT" | shasum -a 256 | awk '{print $1}')"
  export SCCACHE_SERVER_UDS="$socket_directory/0.18.0-$root_hash.sock"
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
