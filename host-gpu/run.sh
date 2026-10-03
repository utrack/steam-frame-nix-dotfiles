# host-gpu-run INDEX PROGRAM [ARGS...]
#
# Starts a Nix program with the host's GPU drivers. On the Frame that's
# SteamOS's Mesa: OpenGL through Zink on the Turnip Vulkan driver (there's no
# native OpenGL driver). Set before this text: tools, host_lib, icd_dir,
# nix_glibc, scrub.
#
# Nix programs never search the host's library dirs, so the drivers and the
# host libraries they load are linked into one folder on LD_LIBRARY_PATH. That
# works because Nix's glibc is newer than the host's: host libraries load into
# a Nix process, not the other way round. Where Nix has a library too, the
# newer copy is linked (libraries load with newer versions of what they were
# built against), except the ones that pair with the host's driver build.
# INDEX lists the program's Nix libraries: name, file. The folder is rebuilt
# when any of that changes (a SteamOS or Nix update). Programs started from
# the program don't get it (scrub.c).
index=$1
shift

warn() { echo "host-gpu: $*" >&2; }
newest() { printf '%s\n' "$@" | sort -V | tail -n1; }

setup() {
  PATH=$tools/bin
  local host_glibc tops=() icds=() libs key base dir tmp name file pick nix l j
  if [ ! -e "$host_lib/libEGL_mesa.so.0" ]; then
    warn "no Mesa in $host_lib, starting without the host's GPU drivers"
    return 1
  fi
  host_glibc=$(/usr/bin/ldd --version | head -n1 | awk '{ print $NF }')
  if [ "$(newest "$host_glibc" "$nix_glibc")" != "$nix_glibc" ]; then
    warn "host glibc $host_glibc is newer than Nix's $nix_glibc, starting without the host's GPU drivers"
    return 1
  fi

  tops=("$host_lib/libEGL_mesa.so.0")
  for l in libGLX_mesa.so.0 libgbm.so.1 libvulkan.so.1; do
    [ -e "$host_lib/$l" ] && tops+=("$host_lib/$l")
  done
  for j in "$icd_dir"/*.json; do
    [ -e "$j" ] || continue
    l=$(sed -n 's/.*"library_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$j")
    if [[ $l == /* && -e $l ]]; then
      icds+=("$j")
      tops+=("$l")
    fi
  done
  # soname, host file: the drivers and everything they load
  libs=$({
    for l in "${tops[@]}"; do printf '%s\t%s\n' "${l##*/}" "$l"; done
    /usr/bin/ldd "${tops[@]}" 2>/dev/null | awk '$2 == "=>" && $3 ~ /^\// { print $1 "\t" $3 }'
  } | sort -u)

  key=$({
    echo "$index $host_glibc"
    printf '%s\n' "${icds[@]}"
    while IFS=$'\t' read -r name file; do echo "$name $(readlink -f "$file")"; done <<<"$libs"
  } | md5sum | cut -c1-16)
  base=${XDG_RUNTIME_DIR:-/tmp}/host-gpu
  dir=$base/$key
  if [ ! -d "$dir" ]; then
    mkdir -p "$base" && tmp=$(mktemp -d "$base/.new.XXXXXX") && mkdir "$tmp/lib" || return 1
    while IFS=$'\t' read -r name file; do
      case $name in
        # glibc stays Nix's: the program's own loader brings it.
        ld-linux* | libc.so.* | libm.so.* | libmvec.so.* | libpthread.so.* | libdl.so.* | \
          librt.so.* | libresolv.so.* | libutil.so.* | libanl.so.*) continue ;;
      esac
      pick=$(readlink -f "$file")
      case $name in
        libEGL_mesa.so.* | libGLX_mesa.so.* | libgbm.so.*) ;;
        *)
          while read -r nix; do
            [ "$(newest "${pick##*/}" "${nix##*/}")" = "${nix##*/}" ] && pick=$nix
          done < <(awk -F'\t' -v n="$name" '$1 == n { print $2 }' "$index")
          ;;
      esac
      ln -s "$pick" "$tmp/lib/$name"
    done <<<"$libs"
    printf '{"file_format_version": "1.0.0", "ICD": {"library_path": "%s"}}\n' \
      "$host_lib/libEGL_mesa.so.0" >"$tmp/egl_vendor.json"
    if [ ${#icds[@]} -gt 0 ]; then printf '%s\n' "${icds[@]}"; fi >"$tmp/vulkan_icds"
    mv -T "$tmp" "$dir" 2>/dev/null || rm -rf "$tmp"
  fi
  echo "$dir"
}

# The variable with entries matching a pattern removed (from an outer run).
without() {
  local out='' p
  IFS=: read -ra parts <<<"${!1:-}"
  for p in "${parts[@]}"; do
    # shellcheck disable=SC2053 # $2 is a pattern
    [[ -z $p || $p == $2 ]] || out+=${out:+:}$p
  done
  echo "$out"
}

if dir=$(setup); then
  # scrub.so puts these back once the program runs, for the programs it starts.
  HOST_GPU_LD_LIBRARY_PATH=$(without LD_LIBRARY_PATH '*/host-gpu/*/lib')
  HOST_GPU_LD_PRELOAD=$(without LD_PRELOAD "$scrub")
  export HOST_GPU_LD_LIBRARY_PATH HOST_GPU_LD_PRELOAD
  export LD_LIBRARY_PATH=$dir/lib${HOST_GPU_LD_LIBRARY_PATH:+:$HOST_GPU_LD_LIBRARY_PATH}
  export LD_PRELOAD=$scrub${HOST_GPU_LD_PRELOAD:+:$HOST_GPU_LD_PRELOAD}
  export __EGL_VENDOR_LIBRARY_FILENAMES=$dir/egl_vendor.json
  if [ -e "$dir/lib/libGLX_mesa.so.0" ]; then export __GLX_VENDOR_LIBRARY_NAME=mesa; fi
  mapfile -t icds <"$dir/vulkan_icds"
  if [ ${#icds[@]} -gt 0 ]; then
    VK_DRIVER_FILES=$(IFS=:; echo "${icds[*]}")
    export VK_DRIVER_FILES VK_ICD_FILENAMES=$VK_DRIVER_FILES
  fi
  export LIBGL_DRIVERS_PATH=$host_lib/dri GBM_BACKENDS_PATH=$host_lib/gbm
fi
exec "$@"
