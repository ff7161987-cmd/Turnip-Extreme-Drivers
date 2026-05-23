#!/bin/bash -e
set -o pipefail

deps="git meson ninja patchelf unzip curl pip flex bison zip glslangValidator python3"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r29"
ndk="$workdir/$ndkver/toolchains/llvm/prebuilt/linux-x86_64/bin"
mesasrc="https://github.com/whitebelyash/mesa-tu8.git"
srcfolder="mesa"
BUILD_VERSION="${BUILD_VERSION:-1.0}"

run_all(){
    check_deps
    prepare_workdir
    build_lib_for_android gen8
}

check_deps(){
    for deps_chk in $deps; do
        if ! command -v "$deps_chk" >/dev/null 2>&1 ; then
            exit 1
        fi
    done
    pip install mako --break-system-packages &> /dev/null || true
}

prepare_workdir(){
    mkdir -p "$workdir" && cd "$workdir"

    if [ ! -d "$ndkver" ]; then
        curl -sL "https://dl.google.com/android/repository/${ndkver}-linux.zip" -o "${ndkver}-linux.zip" &> /dev/null
        unzip -q "${ndkver}-linux.zip" &> /dev/null
    fi

    rm -rf "$srcfolder"
    git clone "$mesasrc" --depth=1 --no-single-branch "$srcfolder"
    cd "$srcfolder"
    
    echo "#define TUGEN8_DRV_VERSION \"\"" > ./src/freedreno/vulkan/tu_version.h

    # --- GOD MODE: ESTABILIDADE TOTAL E FPS TRAVADO ---
    
    # 1. EXTREME RAIN FIX (Loop Unroll + Shader Prefetch)
    # Força o compilador a desenrolar loops complexos (como gotas de chuva)
    sed -i '/nir_lower_io_to_temporaries/a \    NIR_PASS_V(nir, nir_opt_algebraic_before_ffma);\n    NIR_PASS_V(nir, nir_opt_loop_unroll);' src/freedreno/ir3/ir3_nir.c

    # 2. BYPASS V-SYNC & THROTTLING (No Latency)
    # Remove verificações de flush que podem causar stuttering
    sed -i 's/if (unlikely(device->instance->debug_flags & TU_DEBUG_FLUSHALL))/if (false)/g' src/freedreno/vulkan/tu_cmd_buffer.cc || true
    
    # 3. ZERO-LATENCY MEMORY (Heaps Coerentes)
    sed -i 's/dev->physical_device->has_cached_coherent_memory/true/g' src/freedreno/vulkan/tu_device.cc
    
    # 4. IR3 ILP BOOST (95% Register Efficiency)
    sed -i 's/return (struct ir3_gpu_profile){85, 8, 8, false};/return (struct ir3_gpu_profile){95, 4, 4, true};/' src/freedreno/ir3/ir3_compiler.c
    sed -i 's/rank == chosen_rank && chosen->max_delay < n->max_delay/rank == chosen_rank \&\& chosen->max_delay > n->max_delay/g' src/freedreno/ir3/ir3_sched.c

    # 5. CONCURRENT BINNING (Stability Combo)
    # Força o uso de binning concorrente para evitar quedas bruscas em cidades/chuva
    sed -i 's/uint64_t driver_flags = TU_DEBUG(NOMULTIPOS);/uint64_t driver_flags = TU_DEBUG(NOMULTIPOS) | TU_DEBUG(HIPRIO) | TU_DEBUG(PERF) | TU_DEBUG(FORCE_CONCURRENT_BINNING) | TU_DEBUG(NOLRZ);/' src/freedreno/vulkan/tu_device.cc

    # 6. HACK FP16 (MediumP) Turbo
    sed -i 's/uint64_t mediump_varyings = s->info.linear_varyings |/uint64_t mediump_varyings = 0xffffffffffffffff;/' src/freedreno/ir3/ir3_nir.c
    sed -i 's/NIR_PASS(_, s, nir_lower_mediump_io, nir_var_shader_out, 0, false);/NIR_PASS(_, s, nir_lower_mediump_io, nir_var_shader_out, 0xffffffffffffffff, true);/' src/freedreno/ir3/ir3_nir.c

    # 7. FORCE EARLY Z (Desativando force_late_z)
    sed -i 's/force_late_z = true/force_late_z = false/g' src/freedreno/vulkan/tu_lrz.cc || true
    sed -i 's/shader->fs.lrz.force_late_z = true/shader->fs.lrz.force_late_z = false/g' src/freedreno/vulkan/tu_shader.cc || true

    # 8. WORKLOAD DISTRIBUTION (8 Cores Focus)
    sed -i 's/device->submit_count > 1/true/g' src/freedreno/vulkan/tu_device.cc || true
    
    # 9. SHADER PREFETCH BOOST
    sed -i 's/TU_DEBUG(NODESCPREFETCH)/0/g' src/freedreno/vulkan/tu_device.cc || true

    # Remover bloqueio de LTO
    sed -i '/error(.Building Mesa with LTO is not supported./d' meson.build
}

build_lib_for_android(){
    cd "$workdir/$srcfolder"
    git checkout "origin/$1"
    
    if [ -d "../../patches" ]; then
        for p in ../../patches/*.patch; do
            git apply --ignore-whitespace "$p" || echo "Falha ao aplicar $p, continuando..."
        done
    fi

    sed -i 's/ (%s)//g' src/freedreno/vulkan/tu_device.cc || true

    # Fixes de compilação
    sed -i '/a7xx_gen1 = GPUProps(/a \        has_early_preamble = False,' src/freedreno/common/freedreno_devices.py || true
    sed -i 's/typedef const native_handle_t\* buffer_handle_t;/typedef void\* buffer_handle_t;/g' include/android_stub/cutils/native_handle.h || true
    sed -i 's/, hnd->handle/, (void \*)hnd->handle/g' src/util/u_gralloc/u_gralloc_fallback.c || true
    sed -i 's/native_buffer->handle->/((const native_handle_t \*)native_buffer->handle)->/g' src/vulkan/runtime/vk_android.c || true
    sed -i 's/anb->handle->/((const native_handle_t \*)anb->handle)->/g' src/vulkan/runtime/vk_android.c || true

    mkdir -p "$workdir/bin"
    ln -sf "$ndk/clang" "$workdir/bin/cc"
    ln -sf "$ndk/clang++" "$workdir/bin/c++"
    export PATH="$workdir/bin:$ndk:$PATH"
    export CC=clang
    export CXX=clang++
    export AR=llvm-ar
    export RANLIB=llvm-ranlib
    export STRIP=llvm-strip
    export OBJDUMP=llvm-objdump
    export OBJCOPY=llvm-objcopy
    
    # Flags GOD MODE
    export LDFLAGS="-fuse-ld=lld -Wl,--as-needed -Wl,--lto-O3"
    export CFLAGS="-Ofast -march=armv8-a -fno-plt -fno-semantic-interposition -flto=thin -mllvm -adreno-inline-threshold=500"
    export CXXFLAGS="-Ofast -march=armv8-a -fno-plt -fno-semantic-interposition -flto=thin -mllvm -adreno-inline-threshold=500"

    local cver="36"
    [ ! -f "$ndk/aarch64-linux-android${cver}-clang" ] && cver="35"
    [ ! -f "$ndk/aarch64-linux-android${cver}-clang" ] && cver="34"

    cat <<EOF >"android-aarch64.txt"
[binaries]
ar = '$ndk/llvm-ar'
c = ['ccache', '$ndk/aarch64-linux-android${cver}-clang']
cpp = ['ccache', '$ndk/aarch64-linux-android${cver}-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
c_ld = '$ndk/ld.lld'
cpp_ld = '$ndk/ld.lld'
strip = '$ndk/llvm-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$ndk/pkg-config', '/usr/bin/pkg-config']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

    cat <<EOF >"native.txt"
[build_machine]
c = ['ccache', 'clang']
cpp = ['ccache', 'clang++']
ar = 'llvm-ar'
strip = 'llvm-strip'
c_ld = 'ld.lld'
cpp_ld = 'ld.lld'
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

    meson setup build-android-aarch64 \
        --cross-file "android-aarch64.txt" \
        --native-file "native.txt" \
        --prefix "/tmp/turnip-$1" \
        -Dbuildtype=release \
        -Db_lto=true \
        -Db_lto_mode=thin \
        -Doptimization=3 \
        -Dstrip=true \
        -Dplatforms=android \
        -Dvideo-codecs= \
        -Dplatform-sdk-version=36 \
        -Dandroid-stub=true \
        -Dgallium-drivers= \
        -Dvulkan-drivers=freedreno \
        -Dvulkan-beta=true \
        -Dfreedreno-kmds=kgsl \
        -Degl=disabled \
        -Dandroid-libbacktrace=disabled

    ninja -C build-android-aarch64 install

    if [ ! -f "/tmp/turnip-$1/lib/libvulkan_freedreno.so" ]; then
        exit 1
    fi

    cd "/tmp/turnip-$1/lib"
    
    cat <<EOF >"meta.json"
{
  "schemaVersion": 1,
  "name": "Turnip Extreme Performance",
  "description": "GOD MODE V2 - Einstein/Tesla Surgery (Extreme Rain Fix + 60 FPS Fixed)",
  "author": "ff7161987-cmd",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "Vulkan 1.4.348",
  "minApi": 28,
  "libraryName": "libvulkan_freedreno.so"
}
EOF

    local zip_name="turnip-$1-V${BUILD_VERSION}.zip"
    zip -9 "/tmp/$zip_name" libvulkan_freedreno.so meta.json
    cp "/tmp/$zip_name" "$workdir/"
}

run_all
