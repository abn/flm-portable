# FastFlowLM Portable Linux Distribution

This repository contains the packaging and distribution configurations to build and run a fully portable, self-contained Linux version of **FastFlowLM (FLM)**.

FastFlowLM is an inference runtime optimized for running Large Language Models, vision-language models, and speech models on **AMD Ryzen™ AI NPUs** (XDNA2).

This portable bundle includes all userspace dependencies (including AMD XRT libraries, FFmpeg, and required plugins), enabling it to run on any modern Linux distribution without requiring host-level installation of XRT or multimedia stacks.

---

## Prerequisites

To run FastFlowLM on the host or inside a container, your system must have:
1. The `amdxdna` kernel-side driver loaded (upstream in kernel 7.0+, or via `amdxdna-dkms`).
2. Host memory lock limits set to `unlimited`. Add the following to `/etc/security/limits.d/99-amdxdna.conf` and reboot:
   ```ini
   * soft memlock unlimited
   * hard memlock unlimited
   ```

---

## Local Development Commands

We provide a `Makefile` to simplify local building and testing using Podman:

```bash
# Show the help menu
make

# Build the staging container image
make image/build

# Extract the bundled files to your local workspace
make image/extract

# Run a dynamic linkage check inside a clean container
make image/test

# Create the compressed tarball for distribution
make bundle/tar

# Clean build outputs
make clean
```

---

## Running on the Host

After extracting the bundle (or downloading the release tarball), run FastFlowLM using the wrapper script:

```bash
./flm-wrapper list
./flm-wrapper run llama3.2:1b
```

---

## Running Containerized (Under SELinux)

To run the portable bundle inside a clean container using Podman under SELinux (e.g., on Fedora, Red Hat, or CentOS), mount the accelerator device, configure locked memory limits, and mount the files with appropriate SELinux context flags:

```bash
podman run --rm -it \
  --device /dev/accel/accel0 \
  --ulimit memlock=-1:-1 \
  -v $(pwd):/workspace:z \
  -v ~/.config/flm:/root/.config/flm:z \
  registry.fedoraproject.org/fedora:44 \
  /workspace/flm-wrapper run llama3.2:1b
```

### Options Breakdown:
- `--device /dev/accel/accel0`: Mounts the hardware AMD Ryzen AI NPU device node into the container.
- `--ulimit memlock=-1:-1`: Permits the container process to lock unlimited host memory. **This is critical** for the NPU runtime to allocate Buffer Objects (BOs). Without it, the NPU driver will crash immediately.
- `-v /path:/mount:z`: The `:z` volume suffix is required under SELinux. It tells Podman to automatically relabel the mounted directories with shared SELinux container labels (`container_file_t`), permitting containerized processes to read/write the host workspace and model storage safely.

---

## Project Structure

- `bin/`: Contains the target `flm` binary along with the preloaded XRT shared libraries (`libxrt_core.so.2`, etc.).
- `lib64/`: Contains the bundled userspace libraries (e.g. FFmpeg, Boost, and XRT driver shims).
- `share/flm/`: Contains configuration files (`model_list.json`), AMD AIE firmware binaries (`xclbins/`), and the package build Bill of Materials (`BOM.txt`).
- `flm-wrapper`: Core shell wrapper. Sets `LD_LIBRARY_PATH`, `XILINX_XRT`, and `CMAKE_XCLBIN_PREFIX`.
