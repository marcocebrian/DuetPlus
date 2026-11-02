#!/bin/bash
# Builds libduet_all.a for iOS device + simulator (arm64).
set -e
cd "$(dirname "$0")"
for p in OS SIMULATOR; do
  if [ $p = OS ]; then SDK=iphoneos; else SDK=iphonesimulator; fi
  B=build-ios/$SDK
  cmake -S . -B $B -G Xcode -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=$SDK \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DDUET_STATIC=ON >/dev/null
  cmake --build $B --config Release -- -quiet -sdk $SDK CODE_SIGNING_ALLOWED=NO
  libtool -static -o build-ios/libduet_$SDK.a $B/Release-$SDK/libduet.a $B/Release-$SDK/libopus.a
done
ls -la build-ios/*.a
