#!/bin/sh
# mkdir -p third_party

# curl -LO 'https://bellard.org/quickjs/quickjs-2021-03-27.tar.xz'
# tar xvf quickjs-2021-03-27.tar.xz
# rm quickjs-2021-03-27.tar.xz
# mv quickjs-2021-03-27 third_party/quickjs

curl -LO 'https://mirror.msys2.org/mingw/mingw64/mingw-w64-x86_64-winpthreads-git-10.0.0.r234.g283e5b23a-1-any.pkg.tar.zst'
tar xvf mingw-w64-x86_64-winpthreads-git-10.0.0.r234.g283e5b23a-1-any.pkg.tar.zst  -C third_party mingw64
rm mingw-w64-x86_64-winpthreads-git-10.0.0.r234.g283e5b23a-1-any.pkg.tar.zst