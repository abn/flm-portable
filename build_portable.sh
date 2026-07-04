#!/bin/bash
set -e

# Helper to get absolute paths from ldd safely without breaking under set -e
ldd_paths() {
    ldd "$1" 2>/dev/null | grep -o '/[^ ]\+' || true
}

echo "=== Step 1: Enabling COPR abn/amd-npu ==="
if ! dnf copr --help &>/dev/null; then
    dnf install -y 'dnf-command(copr)'
fi
dnf copr enable -y abn/amd-npu

echo "=== Step 2: Installing fastflowlm package ==="
dnf install -y fastflowlm

# Staging area inside the workspace mount
STAGING_DIR="/workspace"
mkdir -p "$STAGING_DIR/bin"
mkdir -p "$STAGING_DIR/lib64/flm"
mkdir -p "$STAGING_DIR/share"

echo "=== Step 3: Copying binaries and resources ==="
# Copy fastflowlm binary
cp -pv /usr/bin/flm "$STAGING_DIR/bin/"

# Copy fastflowlm share directory (holds model_list.json and xclbins)
if [ -d /usr/share/flm ]; then
    cp -rpv /usr/share/flm/* "$STAGING_DIR/share/"
fi

# Copy fastflowlm specific library directory (the model .so files)
if [ -d /usr/lib64/flm ]; then
    cp -rpv /usr/lib64/flm/* "$STAGING_DIR/lib64/flm/"
elif [ -d /usr/lib/flm ]; then
    cp -rpv /usr/lib/flm/* "$STAGING_DIR/lib64/flm/"
fi

echo "=== Step 4: Gathering dynamic library dependencies ==="
LIBS=$(ldd_paths /usr/bin/flm)

for LIB in $LIBS; do
    LIB_NAME=$(basename "$LIB")
    
    # Exclude system-critical, compiler runtime, and AMD XRT hardware libraries
    case "$LIB_NAME" in
        libc.so*|libm.so*|libpthread.so*|libdl.so*|ld-linux-x86-64.so*|libstdc++.so*|libgcc_s.so*|libgomp.so*|libxrt_coreutil.so*|libaiebu.so*|libudev.so*|libselinux.so*|libresolv.so*|libcrypt.so*|libuuid.so*|libmvec.so*|librt.so*)
            echo "-> Excluded (host/system provided): $LIB_NAME"
            ;;
        *)
            if [ -f "$LIB" ]; then
                echo "-> Bundling: $LIB_NAME"
                cp -pv "$LIB" "$STAGING_DIR/lib64/flm/"
            fi
            ;;
    esac
done

echo "=== Step 5: Resolving recursive dependencies for bundled libraries ==="
RESOLVED=1
iteration=1
while [ $RESOLVED -ne 0 ] && [ $iteration -lt 10 ]; do
    echo "--- Dependency Resolution Pass $iteration ---"
    RESOLVED=0
    iteration=$((iteration + 1))
    
    # Use a temporary file to hold the list of libraries to avoid reading while writing
    libs_to_check=$(find "$STAGING_DIR/lib64/flm" -type f ! -type l)
    
    for BUNDLED_LIB in $libs_to_check; do
        DEPS=$(ldd_paths "$BUNDLED_LIB")
        for DEP in $DEPS; do
            DEP_NAME=$(basename "$DEP")
            case "$DEP_NAME" in
                libc.so*|libm.so*|libpthread.so*|libdl.so*|ld-linux-x86-64.so*|libstdc++.so*|libgcc_s.so*|libgomp.so*|libxrt_coreutil.so*|libaiebu.so*|libudev.so*|libselinux.so*|libresolv.so*|libcrypt.so*|libuuid.so*|libmvec.so*|librt.so*)
                    # Skip system/driver libraries
                    ;;
                *)
                    if [ -f "$DEP" ] && [ ! -f "$STAGING_DIR/lib64/flm/$DEP_NAME" ]; then
                        echo "-> Bundling recursive dep of $(basename "$BUNDLED_LIB"): $DEP_NAME"
                        cp -pv "$DEP" "$STAGING_DIR/lib64/flm/"
                        RESOLVED=1
                    fi
                    ;;
            esac
        done
    done
done

echo "=== Step 6: Creating runtime wrapper script ==="
cat << 'EOF' > "$STAGING_DIR/flm-wrapper"
#!/bin/bash
# Get the directory where the wrapper script resides
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configure runtime library path prioritizing bundled libraries, then host XRT libraries
export LD_LIBRARY_PATH="$SELF_DIR/lib64/flm:$SELF_DIR/lib64:/opt/xilinx/xrt/lib64:/opt/xilinx/xrt/lib:${LD_LIBRARY_PATH}"

# Override the XCLBIN search prefix to point inside the portable folder
export CMAKE_XCLBIN_PREFIX="$SELF_DIR/share"

# Run the official binary passing all arguments
exec "$SELF_DIR/bin/flm" "$@"
EOF

chmod +x "$STAGING_DIR/flm-wrapper"

echo "=== Build Complete! ==="
