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
    # Compilando Turnip (Adreno)
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

    # --- UNIVERSAL GOD MODE (v26.4.0) ---
    
    # 1. UNIVERSAL NIR ALGEBRAICS (Adreno & Mali)
    # Otimiza a matemática dos shaders na base da Mesa
    sed -i '/nir_opt_algebraic(nir)/a \    while(nir_opt_algebraic(nir)) { nir_opt_constant_folding(nir); }' src/compiler/nir/nir_opt_algebraic.c || true

    # 2. GLOBAL MEMORY POOL AGGRESSION
    # Aumenta o limite de cache de memória para evitar quedas de FPS
    sed -i 's/OS_MEMORY_MB /OS_MEMORY_MB * 2 /g' src/util/os_memory.h || true

    # 3. LOOP UNROLLING BOOST
    # Força o compilador a desenrolar loops para execução direta na GPU
    sed -i 's/limit = 16/limit = 64/g' src/compiler/nir/nir_opt_loop_unroll.c || true

    # 4. MALI/MEDIATEK SPECIFIC HACKS (Panfrost/Bifrost/Valhall)
    # Otimiza o acesso à memória em GPUs Mali
    sed -i 's/bifrost_force_pack = false/bifrost_force_pack = true/g' src/panfrost/lib/pan_props.c || true
    sed -i 's/allow_unaligned_access = true/allow_unaligned_access = false/g' src/panfrost/lib/pan_layout.c || true

    # 5. ADRENO TURBO BINNING (A6xx-A8xx)
    sed -i 's/TU_DEBUG(NOMULTIPOS)/TU_DEBUG(NOMULTIPOS) | TU_DEBUG(FORCE_CONCURRENT_BINNING) | TU_DEBUG(HIPRIO) | TU_DEBUG(PERF) | TU_DEBUG(NOLRZ)/g' src/freedreno/vulkan/tu_device.cc || true

    # 6. ULTRA-AGGRESSIVE IR3 SCHEDULING
    sed -i 's/chosen->max_delay < n->max_delay/chosen->max_delay > n->max_delay/g' src/freedreno/ir3/ir3_sched.c || true
    sed -i 's/rank == chosen_rank/true/g' src/freedreno/ir3/ir3_sched.c || true

    # 7. MATH APPROXIMATION (Fastest Math)
    sed -i '/nir_lower_io_to_temporaries/a \    NIR_PASS_V(nir, nir_opt_algebraic_before_ffma);\n    NIR_PASS_V(nir, nir_opt_constant_folding);\n    NIR_PASS_V(nir, nir_opt_copy_prop_vars);' src/freedreno/ir3/ir3_nir.c || true

    # 8. FIXED THREADS FOR 8 CORES
    sed -i 's/device->submit_count > 1/true/g' src/freedreno/vulkan/tu_device.cc || true

    # --- HACKS ANTERIORES MANTIDOS ---
    sed -i 's/return (struct ir3_gpu_profile){85, 8, 8, false};/return (struct ir3_gpu_profile){95, 4, 4, true};/' src/freedreno/ir3/ir3_compiler.c
    sed -i '/error(.Building Mesa with LTO is not supported./d' meson.build
    sed -i 's/uint64_t mediump_varyings = s->info.linear_varyings |/uint64_t mediump_varyings = 0xffffffffffffffff;/' src/freedreno/ir3/ir3_nir.c
    sed -i 's/NIR_PASS(_, s, nir_lower_mediump_io, nir_var_shader_out, 0, false);/NIR_PASS(_, s, nir_lower_mediump_io, nir_var_shader_out, 0xffffffffffffffff, true);/' src/freedreno/ir3/ir3_nir.c
}

build_lib_for_android(){
    cd "$workdir/$srcfolder"
    git checkout "origin/$1"
    
    if [ -d "../../patches" ]; then
        for p in ../../patches/*.patch; do
            git apply "$p" || echo "Falha ao aplicar $p, continuando..."
        done
    fi

    sed -i 's/ (%s)//g' src/freedreno/vulkan/tu_device.cc || true
    sed -i 's/ (%s)//g' src/freedreno/vulkan/tu_device.c || true

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
    
    export LDFLAGS="-fuse-ld=lld -Wl,--as-needed -Wl,--lto-O3"
    export CFLAGS="-Ofast -march=armv8-a -fno-plt -fno-semantic-interposition -flto=thin"
    export CXXFLAGS="-Ofast -march=armv8-a -fno-plt -fno-semantic-interposition -flto=thin"

    GITHASH=$(git rev-parse --short HEAD)

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
        -Dgallium-drivers=panfrost \
        -Dvulkan-drivers=freedreno,panfrost \
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
  "description": "Universal God Mode - v26.4.0 (Adreno + Mali/MediaTek Ultimate FPS)",
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
    # Adicionando suporte Mali se compilado
    [ -f "libvulkan_panfrost.so" ] && zip -9 "/tmp/$zip_name" libvulkan_panfrost.so
    cp "/tmp/$zip_name" "$workdir/"
}

run_all
