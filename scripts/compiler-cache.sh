#!/bin/bash
# Configure the same environment before reuse checks and compilation.
configure_compiler_cache() {
  local sccache_binary cache_root
  cache_root="${FRITZ_CACHE_ROOT:-$FRITZ_BUILD_ROOT}"
  if ! sccache_binary="$(mise which sccache)"; then
    echo 'error: run mise trust mise.toml && mise install before building Fritz' >&2
    return 1
  fi
  export RUSTC_WRAPPER="$sccache_binary"
  export SCCACHE_DIR="$cache_root/compiler-cache/rust"
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
  root_hash="$(printf '%s' "$cache_root" | shasum -a 256 | awk '{print $1}')"
  export SCCACHE_SERVER_UDS="$socket_directory/0.18.0-$root_hash.sock"
  mkdir -p "$SCCACHE_DIR"
  xcode_cache_settings=(
    COMPILATION_CACHE_ENABLE_CACHING=YES
    "COMPILATION_CACHE_CAS_PATH=$cache_root/compiler-cache/xcode"
  )
}

start_compiler_cache() {
  # Runner-local outputs share one compiler-cache daemon and startup lock.
  local cache_root="${FRITZ_CACHE_ROOT:-$FRITZ_BUILD_ROOT}"
  # Delay daemon startup until an app actually needs compilation.
  /usr/bin/lockf -k "$cache_root/compiler-cache/server-start.lock" \
    "$RUSTC_WRAPPER" "$(command -v rustc)" -vV >/dev/null
}
