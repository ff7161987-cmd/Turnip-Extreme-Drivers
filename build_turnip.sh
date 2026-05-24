#!/bin/bash
set -e

# ============================================================
# Turnip Adreno 6xx – OMEGA BUILD SAFE (O CHEFÃO FINAL)
# Focado em SD870: Occupancy Dinâmico + LRZ Pro + UCHE Tuning
# ============================================================

WORK_DIR="turnip_workdir"
NDK_VER="r26b"
NDK_URL="https://dl.google.com/android/repository/android-ndk-${NDK_VER}-linux.zip"

mkdir -p $WORK_DIR
cd $WORK_DIR

# 1. Setup NDK
if [ ! -d "android-ndk-${NDK_VER}" ]; then
    curl -L $NDK_URL -o ndk.zip
    unzip -q ndk.zip
    rm ndk.zip
fi
NDK_PATH=$(pwd)/android-ndk-${NDK_VER}

# 2. Clone Mesa Bleeding Edge
if [ ! -d "mesa" ]; then
    git clone --depth 1 https://gitlab.freedesktop.org/mesa/mesa.git mesa
fi
cd mesa

# 3. CIRURGIAS OMEGA SAFE (SEM TELA PRETA)

# A. Occupancy Dinâmico: Sugerir economia de registradores sem forçar erro
sed -i 's/ir3_shader_debug_regs = false/ir3_shader_debug_regs = true/g' src/freedreno/ir3/ir3_compiler.c || true

# B. LRZ Pro: Descarte agressivo de pixels escondidos (Ganho de FPS em cidades)
sed -i 's/tu_lrz_clear_type = 0/tu_lrz_clear_type = 1/g' src/freedreno/vulkan/tu_lrz.c || true

# C. UCHE Tuning: Maximizar uso do cache unificado para SD870
sed -i 's/tu_device_get_cache_size(device) \/ 2/tu_device_get_cache_size(device)/g' src/freedreno/vulkan/tu_device.c || true

# D. FP16 Turbo: Acelerar shaders de luz e reflexos
sed -i 's/lowp_as_mediump = false/lowp_as_mediump = true/g' src/freedreno/vulkan/tu_shader.cc || true

# 4. Cross-file
cat <<EOF > android-arm64.txt
[binaries]
c = '$NDK_PATH/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android34-clang'
cpp = '$NDK_PATH/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android34-clang++'
ar = '$NDK_PATH/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar'
strip = '$NDK_PATH/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip'
[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8-a'
endian = 'little'
EOF

# 5. Build
meson setup build-android --cross-file android-arm64.txt \
    -Dbuildtype=release \
    -Dstrip=true \
    -Dplatforms=android \
    -Dplatform-sdk-version=34 \
    -Dandroid-stub=true \
    -Dvulkan-drivers=freedreno \
    -Dfreedreno-kmds=kgsl,msm \
    -Dcpp_args="-O3 -ffast-math -flto -DTU_MAX_THREADS=1024 -DCS_BUFFER_SIZE=32768" \
    -Dc_args="-O3 -ffast-math -flto -DTU_MAX_THREADS=1024 -DCS_BUFFER_SIZE=32768"

ninja -C build-android

# 6. Package
mkdir -p output
cp build-android/src/freedreno/vulkan/libvulkan_freedreno.so output/
cat <<EOF > output/meta.json
{
  "schemaVersion": 1,
  "name": "Turnip OMEGA BUILD SAFE",
  "description": "Omega Build: Occupancy Dinâmico + LRZ Pro + UCHE Tuning. Performance extrema sem tela preta.",
  "author": "Manus-Einstein",
  "packageVersion": "2.0",
  "vendor": "Mesa",
  "driverVersion": "Vulkan 1.3",
  "minApi": 28,
  "libraryName": "libvulkan_freedreno.so"
}
EOF

cd output
zip -r ../../Turnip-Omega-Safe-SD870.zip ./*
