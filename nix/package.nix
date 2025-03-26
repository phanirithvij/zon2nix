{
  lib,
  stdenv,
  zig,
  nix,
  callPackage,
}:
stdenv.mkDerivation {
  pname = "zon2nix";
  version = "0.1.2";

  src = lib.cleanSource ../.;

  nativeBuildInputs = [
    zig.hook
  ];

  postPatch = ''
    ln -s ${callPackage ./deps.nix { }} $ZIG_GLOBAL_CACHE_DIR/p
  '';

  zigBuildFlags = [
    #"-Doptimize=ReleaseSmall"
    "-Dnix=${lib.getExe nix}"
    "-Dlinkage=${if stdenv.hostPlatform.isStatic then "static" else "dynamic"}"
  ];

  zigCheckFlags = [
    "-Dnix=${lib.getExe nix}"
    "-Dlinkage=${if stdenv.hostPlatform.isStatic then "static" else "dynamic"}"
  ];
}
