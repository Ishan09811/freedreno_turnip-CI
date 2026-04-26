#!/bin/bash -e
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

deps="meson ninja patchelf unzip curl pip flex bison zip git"
workdir="$(pwd)/turnip_workdir"
magiskdir="$workdir/turnip_module"
ndkver="android-ndk-r29c"
sdkver="35"
mesasrc="https://gitlab.freedesktop.org/mesa/mesa.git"

commit=""
commit_short=""
mesa_version=""
vulkan_version=""
clear

run_all(){
    check_deps
	prepare_workdir
	build_lib_for_android
	port_lib_for_magisk
}

check_deps(){
	sudo apt remove meson -y &>/dev/null || true
	pip install meson

	sudo apt install -y libssl-dev

	echo "Checking system for required Dependencies ..."
	for deps_chk in $deps;
		do
			sleep 0.25
			if command -v "$deps_chk" >/dev/null 2>&1 ; then
				echo -e "$green - $deps_chk found $nocolor"
			else
				echo -e "$red - $deps_chk not found, can't countinue. $nocolor"
				deps_missing=1
			fi;
		done

		if [ "$deps_missing" == "1" ]; then 
			echo "Please install missing dependencies" && exit 1
		fi

	echo "Installing python dependencies (mako, pyyaml) ..." $'\n'
	pip install mako pyyaml &> /dev/null

	echo "Downloading latest glslangValidator for Mesa main..."
    mkdir -p "$workdir/bin"
    cd "$workdir"
    curl -L https://github.com/KhronosGroup/glslang/releases/download/main-tot/glslang-main-linux-Release.zip -o glslang.zip &> /dev/null
    
    unzip -o glslang.zip -d glslang_temp &> /dev/null
    find glslang_temp -name "glslangValidator" -type f -exec cp {} "$workdir/bin/" \;
    
    chmod +x "$workdir/bin/glslangValidator"
    rm -rf glslang.zip glslang_temp
    export PATH="$workdir/bin:$PATH"
    
    CURRENT_GLSLANG=$(glslangValidator -v | head -n 1)
    echo -e "$green - glslangValidator updated to: $CURRENT_GLSLANG $nocolor"
    cd ..
}

prepare_workdir(){
    echo "Creating and entering to work directory ..." $'\n'
	mkdir -p "$workdir" && cd "$workdir"
	
	if [ -n "$ANDROID_NDK_LATEST_HOME" ] && [ -d "$ANDROID_NDK_LATEST_HOME" ]; then
		echo -e "$green- Using pre-installed NDK at: $ANDROID_NDK_LATEST_HOME $nocolor"
		export NDK_PATH="$ANDROID_NDK_LATEST_HOME"
	else
		if [ ! -d "$ndkver" ]; then
			echo "Downloading $ndkver from google server ..." $'\n'
			curl -L https://dl.google.com/android/repository/"$ndkver"-linux.zip --output "$ndkver"-linux.zip &> /dev/null
			echo "Extracting $ndkver to a folder ..." $'\n'
			unzip "$ndkver"-linux.zip  &> /dev/null
		fi
		export NDK_PATH="$workdir/$ndkver"
	fi

	if [ -d mesa ]; then
		echo "Removing old mesa ..." $'\n'
		rm -rf mesa
	fi
	
	echo "Cloning latest mesa main branch ..." $'\n'
	git clone --depth=1 "$mesasrc" &> /dev/null
	cd mesa

	echo "Updating internal Vulkan headers to latest Khronos spec..."
	git clone --depth=1 https://github.com/KhronosGroup/Vulkan-Headers.git vk_headers_temp &> /dev/null
	cp -rf vk_headers_temp/include/vulkan/* include/vulkan/
	rm -rf vk_headers_temp
	echo -e "$green- Vulkan headers updated successfully. $nocolor"
	
	commit_short=$(git rev-parse --short HEAD)
	commit=$(git rev-parse HEAD)
	mesa_version=$(cat VERSION | xargs)
	
	# Extract version from updated headers
	v_header="include/vulkan/vulkan_core.h"
	major=$(grep "#define VK_API_VERSION_MAJOR" $v_header | awk '{print $3}')
	minor=$(grep "#define VK_API_VERSION_MINOR" $v_header | awk '{print $3}')
	patch=$(grep "#define VK_HEADER_VERSION " $v_header | head -n 1 | awk '{print $3}')
	vulkan_version="$major.$minor.$patch"
}

build_lib_for_android(){
	echo "Creating meson cross file ..." $'\n'
	ndk_bin="$NDK_PATH/toolchains/llvm/prebuilt/linux-x86_64/bin"
	ndk_sysroot="$NDK_PATH/toolchains/llvm/prebuilt/linux-x86_64/sysroot"

	cat <<EOF >"android-aarch64"
[binaries]
ar = '$ndk_bin/llvm-ar'
c = ['$ndk_bin/aarch64-linux-android$sdkver-clang']
cpp = ['$ndk_bin/aarch64-linux-android$sdkver-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '-static-libstdc++']
strip = '$ndk_bin/llvm-strip'
pkgconfig = ['env', 'PKG_CONFIG_LIBDIR=NDKDIR/pkgconfig', '/usr/bin/pkg-config']

[built-in options]
c_link_args = ['-fuse-ld=lld']
cpp_link_args = ['-fuse-ld=lld']

[properties]
needs_exe_wrapper = true
sys_root = '$ndk_sysroot'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

	echo "Generating build files ..." $'\n'
	meson setup build-android-aarch64 \
		--cross-file "$(pwd)/android-aarch64" \
		-Dbuildtype=release \
		-Dplatforms=android \
		-Dplatform-sdk-version=$sdkver \
		-Dandroid-stub=true \
		-Dgallium-drivers= \
		-Dvulkan-drivers=freedreno \
		-Dvulkan-beta=true \
		-Dfreedreno-kmds=kgsl \
		-Db_lto=false \
		-Degl=disabled

	echo "Compiling build files ..." $'\n'
	ninja -C build-android-aarch64 src/freedreno/vulkan/libvulkan_freedreno.so
}

port_lib_for_magisk(){
	echo "Locating compiled driver..." $'\n'
    
    compiled_lib=$(find "$workdir/mesa/build-android-aarch64" -name "libvulkan_freedreno.so" -type f | head -n 1)
    
    if [ -z "$compiled_lib" ]; then
        echo -e "$red- Build failed! libvulkan_freedreno.so was never linked. $nocolor"
        # Check if ninja actually tried to build it
        if [ ! -f "$workdir/mesa/build-android-aarch64/build.ninja" ]; then
             echo "build.ninja is missing! Meson setup failed."
        fi
        exit 1
    fi

    echo -e "$green- Found driver at: $compiled_lib $nocolor"

	echo "Using patchelf to match soname ..."  $'\n'
	cp "$compiled_lib" "$workdir"
	cd "$workdir"
	patchelf --set-soname vulkan.adreno.so libvulkan_freedreno.so
	mv libvulkan_freedreno.so vulkan.ad07XX.so

	mkdir -p "$magiskdir" && cd "$magiskdir"
	date=$(date +'%b %d, %Y')

	cat <<EOF >"meta.json"
{
  "schemaVersion": 1,
  "name": "Mesa Turnip Driver - $date",
  "description": "Vulkan $vulkan_version",
  "author": "mesa",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "$mesa_version",
  "minApi": 27,
  "libraryName": "vulkan.ad07XX.so"
}
EOF

	echo "Copying necessary files from work directory ..." $'\n'
	cp "$workdir"/vulkan.ad07XX.so "$magiskdir"

	echo "Packing files into adrenotool package ..." $'\n'
	zip -r "$workdir"/turnip_"$mesa_version"_"$commit_short".zip ./*

	cd "$workdir"
	echo "https://gitlab.freedesktop.org/mesa/mesa/-/commit/$commit" > description
	echo "Turnip Driver - $mesa_version - $commit_short" > release
	echo "$mesa_version"_"$commit_short" > tag

	if [ ! -f "$workdir"/turnip_"$mesa_version"_"$commit_short".zip ]; then 
		echo -e "$red-Packing failed!$nocolor" && exit 1
	else 
		echo -e "$green-All done, you can take your zip from here:$nocolor" 
		echo "$workdir"/turnip_"$mesa_version"_"$commit_short".zip
	fi
}

run_all
