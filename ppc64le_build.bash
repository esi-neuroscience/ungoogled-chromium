#!/bin/bash

echo "#####################"
echo "IT IS RECOMMENDED TO RUN THIS BUILD SCRIPT ON FEDORA 30!"
echo "#####################"
echo "If any error occurs, please refer to https://wiki.raptorcs.com/wiki/Porting/Chromium for missing dependencies or others."
echo "#####################"

set -eux

# cp -r /usr/lib/python3.7/site-packages/xcbgen /usr/lib/python2.7/site-packages

#export CCACHE_MAXSIZE=25G

#du -sh ccache/ || echo
#du -sh build/llvm-project/ || echo

env

#mkdir -p ccache
#export CCACHE_BASEDIR=${PWD}
#export CCACHE_DIR=${PWD}/ccache

#mkdir ccache_bin
#cd ccache_bin

#ln -s "$(which ccache)" ccache
#ln -s "${PWD}/ccache" clang
#ln -s "${PWD}/ccache" clang++

#NOCCACHE_PATH="${PATH}"
#export PATH="${PWD}:${PATH}"

# Use local CMAKE build 
export PATH=/root/cmake-3.13.5/bin:$PATH

# Ensure we're using Python2 and the correct local cmake
python --version
which cmake
which clang
which clang++

ls -lGha

#cd ../

# On subsequent re-runs, just delete the build/src directory, but don't re-download Chromium
mkdir -p build/download_cache
if [ -z "$(ls -A build/download_cache)" ]; then
    ./utils/downloads.py retrieve -c build/download_cache -i downloads.ini
else
    rm -rf build/src
    rm build/domsubcache.tar.gz
fi
./utils/downloads.py unpack -c build/download_cache -i downloads.ini -- build/src

./utils/prune_binaries.py build/src pruning.list

./utils/patches.py apply build/src patches

patch -p0 --ignore-whitespace -i "$(pwd)/patches/xxx-ppc64le-support.patch" -d build/src --no-backup-if-mismatch --forward
patch -p0 --ignore-whitespace -i "$(pwd)/patches/xxx-ppc64le-libvpx.patch" -d build/src --no-backup-if-mismatch --forward

./utils/domain_substitution.py apply -r domain_regex.list -f domain_substitution.list -c build/domsubcache.tar.gz build/src

cd build/src

sed -i "s/default=False, dest='no_static_libstdcpp'/default=True, dest='no_static_libstdcpp'/" tools/gn/build/gen.py

export CC=clang
export CXX=clang++

mkdir -p out/Default
./tools/gn/bootstrap/bootstrap.py --skip-generate-buildfiles -j$(nproc) -o out/Default/gn
export PATH="${PWD}/out/Default:${PATH}"

cd third_party/libvpx
mkdir source/config/linux/ppc64
./generate_gni.sh
cd ../../

cd third_party/ffmpeg
./chromium/scripts/build_ffmpeg.py linux ppc64
./chromium/scripts/generate_gn.py
./chromium/scripts/copy_config.sh
cd ../../

#cd third_party/dav1d
#./generate_configs.py
#./generate_source.py
#cd ../../

unset CC
unset CXX
#export PATH="${NOCCACHE_PATH}"

cd ../

REVISION=$(grep -Po "(?<=CLANG_REVISION = ').+(?=')" src/tools/clang/scripts/update.py)

if [ -d "llvm-project" ]; then
    cd llvm-project
    git add -A
    git status
    git reset --hard HEAD
    git fetch
    git status
    cd ../
else
    git clone https://github.com/llvm/llvm-project.git
fi

git -C llvm-project checkout "${REVISION}"

mkdir -p llvm_build
cd llvm_build

LLVM_BUILD_DIR=$(pwd)

cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache -DLLVM_ENABLE_PROJECTS="clang;lld" -DLLVM_TARGETS_TO_BUILD="PowerPC" -G "Ninja" ../llvm-project/llvm
ninja -j$(nproc)

cd ../
cd src

cp ../../flags.gn out/Default/args.gn

# Do not use openh264 in ffmpeg (broken in RHEL8) and remove the GNOME-keyring dependency (not available on RHEL 8+/Fedora 31+)
sed "s#../llvm_build#${LLVM_BUILD_DIR}#g" -i out/Default/args.gn
sed "s/use_openh264=true/#use_openh264=true/" -i out/Default/args.gn
echo "use_gnome_keyring=false" >> out/Default/args.gn

./out/Default/gn gen out/Default --fail-on-unused-args
ninja -C out/Default chrome chrome_sandbox chromedriver #stable_rpm
