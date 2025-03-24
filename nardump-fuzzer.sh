#!/usr/bin/env bash

go_=$(time go run nardump.go --sri "$1")
echo "$go_"

#nix_=$(nix-hash --type sha256 --sri "$1")
#nix_=$(nix hash convert --hash-algo sha256 --to sri "$(nix-store --dump "$1" | sha256sum | cut -d' ' -f1)")
nix_=$(time nix hash path "$1")
echo "$nix_"

zig build-exe utils/nar.zig -O ReleaseSmall -femit-bin=/tmp/nar
zig_=$(time /tmp/nar --sri "$1")
echo "$zig_"

#echo -e "go\t$go_\nzig\t$zig_\nnix\t$nix_"
[ "$go_" == "$zig_" ] && [ "$nix_" == "$zig_" ] && echo matches
