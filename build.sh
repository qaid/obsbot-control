#!/bin/bash
set -e
cd "$(dirname "$0")"
clang -fobjc-arc main.m -o obsbot -F vendor -framework VVUVCKit -framework Foundation -framework IOKit -Wl,-rpath,@executable_path/vendor
echo "Built ./obsbot"
