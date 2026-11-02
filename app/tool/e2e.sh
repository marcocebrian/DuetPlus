#!/bin/bash
# Host + guest + late guest as separate processes on localhost.
set -e
cd "$(dirname "$0")/.."
export DUET_LIB="$(cd ../core/build-host && pwd)/libduet.dylib"
rm -rf /tmp/duettest/e2e && mkdir -p /tmp/duettest/e2e
cp assets/demo.webm /tmp/duettest/demo.webm
flutter test test/e2e_test.dart --dart-define=ROLE=host > /tmp/duettest/e2e/host.log 2>&1 &
H=$!
sleep 8
flutter test test/e2e_test.dart --dart-define=ROLE=guest > /tmp/duettest/e2e/guest.log 2>&1 &
G=$!
sleep 22
flutter test test/e2e_test.dart --dart-define=ROLE=late > /tmp/duettest/e2e/late.log 2>&1 &
L=$!
wait $H; echo "host exit $?"; wait $G; echo "guest exit $?"; wait $L; echo "late exit $?"
python3 tool/e2e_compare.py
