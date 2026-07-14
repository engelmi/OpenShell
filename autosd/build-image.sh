#!/usr/bin/bash

aib --verbose \
      build \
      --osbuild-manifest build.json \
      --build-dir _build \
      --distro autosd10 \
      --arch x86_64 \
      --target qemu \
      openshell-qm.aib.yml \
      "localhost/openshell-qm" \
      openshell-qm.aib.x86_64.img
