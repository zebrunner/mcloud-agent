#!/bin/bash
# Runs all *_test.sh scripts; tests for another OS or without their tools skip themselves
cd "$(dirname "$0")" || exit 1

failed=""
for test in *_test.sh; do
  echo "===== ${test}"
  /bin/bash "$test" || failed="${failed} ${test}"
done

echo "====="
if [[ -n "$failed" ]]; then
  echo "FAILED:${failed}"
  exit 1
fi
echo "all tests passed"
