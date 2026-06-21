#!/usr/bin/env bash

rm -rf build

echo "* Creating build folder"
mkdir build

echo "* Copying files"
cp -r jb/* build/

echo "* packing tar.gz file"
tar -czf Winterbreak2.tar.gz -C build .
rm -rf build/*
rm -rf build/.*
mv Winterbreak2.tar.gz build/
