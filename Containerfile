FROM registry.fedoraproject.org/fedora:44 AS builder

# Install plugin-core and enable COPR
RUN dnf install -y 'dnf-command(copr)' findutils && \
    dnf copr enable -y abn/amd-npu && \
    dnf install -y fastflowlm

# Staging area
RUN mkdir -p /dist/bin \
    && mkdir -p /dist/lib64/flm \
    && mkdir -p /dist/share/flm

# Copy fastflowlm binary as flm-real
RUN cp -pv /usr/bin/flm /dist/bin/flm-real

# Copy fastflowlm share directory (holds model_list.json and xclbins)
RUN if [ -d /usr/share/flm ]; then \
        cp -rpv /usr/share/flm/* /dist/share/flm/; \
    fi

# Copy fastflowlm specific library directory (the model .so files)
RUN if [ -d /usr/lib64/flm ]; then \
        cp -rpv /usr/lib64/flm/* /dist/lib64/flm/; \
    elif [ -d /usr/lib/flm ]; then \
        cp -rpv /usr/lib/flm/* /dist/lib64/flm/; \
    fi

# Explicitly copy XRT libraries and plugins to the staging library folder
RUN if [ -d /opt/xilinx/xrt/lib64 ]; then \
        cp -pv /opt/xilinx/xrt/lib64/*.so* /dist/lib64/flm/ || true; \
        cp -pv /opt/xilinx/xrt/lib64/*.so* /dist/lib64/ || true; \
        cp -rpv /opt/xilinx/xrt/lib64/xrt /dist/lib64/flm/ || true; \
        cp -rpv /opt/xilinx/xrt/lib64/xrt /dist/lib64/ || true; \
    fi

# Copy the preloaded dynamic libraries next to the binary
# main.cpp's preload_bundled_libraries() dlopens these from the executable directory (exe_dir + "/")
RUN if [ -d /opt/xilinx/xrt/lib64 ]; then \
        cp -pv /opt/xilinx/xrt/lib64/libxrt_core.so.2* /dist/bin/ || true; \
        cp -pv /opt/xilinx/xrt/lib64/libxrt_coreutil.so.2* /dist/bin/ || true; \
        cp -pv /opt/xilinx/xrt/lib64/libxrt_driver_xdna.so.2* /dist/bin/ || true; \
    fi

# Gather dynamic library dependencies
RUN ldd_paths() { ldd "$1" 2>/dev/null | grep -o '/[^ ]\+' || true; } && \
    LIBS=$(ldd_paths /dist/bin/flm-real) && \
    for LIB in $LIBS; do \
        LIB_NAME=$(basename "$LIB"); \
        case "$LIB_NAME" in \
            libc.so*|libm.so*|libpthread.so*|libdl.so*|ld-linux-x86-64.so*|libstdc++.so*|libgcc_s.so*|libgomp.so*|libudev.so*|libselinux.so*|libresolv.so*|libcrypt.so*|libuuid.so*|libmvec.so*|librt.so*) \
                echo "-> Excluded (host/system provided): $LIB_NAME"; \
                ;; \
            *) \
                if [ -f "$LIB" ]; then \
                    echo "-> Bundling: $LIB_NAME"; \
                    cp -pv "$LIB" /dist/lib64/flm/; \
                fi; \
                ;; \
        esac; \
    done

# Resolve recursive dependencies for bundled libraries
RUN ldd_paths() { ldd "$1" 2>/dev/null | grep -o '/[^ ]\+' || true; } && \
    RESOLVED=1 && \
    iteration=1 && \
    while [ $RESOLVED -ne 0 ] && [ $iteration -lt 10 ]; do \
        echo "--- Dependency Resolution Pass $iteration ---"; \
        RESOLVED=0; \
        iteration=$((iteration + 1)); \
        libs_to_check=$(find /dist/lib64/flm -type f ! -type l); \
        for BUNDLED_LIB in $libs_to_check; do \
            DEPS=$(ldd_paths "$BUNDLED_LIB"); \
            for DEP in $DEPS; do \
                DEP_NAME=$(basename "$DEP"); \
                case "$DEP_NAME" in \
                    libc.so*|libm.so*|libpthread.so*|libdl.so*|ld-linux-x86-64.so*|libstdc++.so*|libgcc_s.so*|libgomp.so*|libudev.so*|libselinux.so*|libresolv.so*|libcrypt.so*|libuuid.so*|libmvec.so*|librt.so*) \
                        ;; \
                    *) \
                        if [ -f "$DEP" ] && [ ! -f "/dist/lib64/flm/$DEP_NAME" ]; then \
                            echo "-> Bundling recursive dep of $(basename "$BUNDLED_LIB"): $DEP_NAME"; \
                            cp -pv "$DEP" /dist/lib64/flm/; \
                            RESOLVED=1; \
                        fi; \
                        ;; \
                esac; \
            done; \
        done; \
    done

# Create the runtime wrapper script named flm
RUN echo '#!/bin/bash' > /dist/flm && \
    echo 'SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' >> /dist/flm && \
    echo 'export XILINX_XRT="$SELF_DIR"' >> /dist/flm && \
    echo 'export LD_LIBRARY_PATH="$SELF_DIR/lib64/flm:$SELF_DIR/lib64:/opt/xilinx/xrt/lib64:/opt/xilinx/xrt/lib:${LD_LIBRARY_PATH}"' >> /dist/flm && \
    echo 'export CMAKE_XCLBIN_PREFIX="$SELF_DIR/share/flm"' >> /dist/flm && \
    echo 'exec "$SELF_DIR/bin/flm-real" "$@"' >> /dist/flm && \
    chmod +x /dist/flm

# Generate comprehensive Bill of Materials (BOM.txt) by mapping staging files back to their RPM packages
RUN for file in $(find /dist -type f); do \
        name=$(basename "$file"); \
        orig_path=$(find /usr/bin /usr/lib64 /lib64 /opt/xilinx -maxdepth 3 -name "$name" -print -quit 2>/dev/null); \
        if [ -n "$orig_path" ]; then \
            rpm -qf --qf "%{NAME}: %{VERSION}-%{RELEASE}\n" "$orig_path" 2>/dev/null; \
        fi; \
    done | sort -u > /dist/share/flm/BOM.txt

FROM scratch
COPY --from=builder /dist /
