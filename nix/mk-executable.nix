{
  pkgs,
  lib,
  stdenv,
  deno2nix,
  ...
}: {
  pname,
  version,
  src,
  bin ? pname,
  entrypoint,
  lockfile,
  config,
  allow ? {},
  additionalDenoFlags ? "",
} @ inputs: let
  inherit (builtins) isString;
  inherit (lib) importJSON concatStringsSep;
  inherit (deno2nix.internal) mkDepsLink mkNpmLink findImportMap;

  allowflag = flag: (
    if (allow ? flag) && allow."${flag}"
    then ["--allow-${flag}"]
    else []
  );

  importMap = findImportMap {
    inherit (inputs) src config importMap;
  };

  #compileCmd = ''
    #deno compile --cached-only --lock=${lockfile} --output=${bin} ${entrypoint}
  #'';

  compileCmd = concatStringsSep " " (
    [
      "deno compile --cached-only"
      "--lock=${lockfile}"
      #"--output=${bin}"
      # "--config=${config}"
    ]
    ++ (
      if (isString importMap)
      then ["--import-map=${importMap}"]
      else []
    )
    ++ (allowflag "all")
    ++ (allowflag "env")
    ++ (allowflag "ffi")
    ++ (allowflag "hrtime")
    ++ (allowflag "net")
    ++ (allowflag "read")
    ++ (allowflag "run")
    ++ (allowflag "sys")
    ++ (allowflag "write")
    ++ [additionalDenoFlags]
    ++ ["${entrypoint}"]
  );
in
  stdenv.mkDerivation {
    inherit pname version src;
    dontFixup = true;

    buildInputs = with pkgs; [deno jq];
    buildPhase = ''
      export DENO_DIR="$TMPDIR/deno2nix"
      #export DENO_DIR=/tmp/deno2nix
      mkdir -p $DENO_DIR
      echo "RUNNING COMPILE COMMAND"
      echo $(deno info --json | jq -r .npmCache)
      ln -s "${mkNpmLink (src + "/${lockfile}")}/registry.npmjs.org" $(deno info --json | jq -r .npmCache)
      ln -s "${mkDepsLink (src + "/${lockfile}")}" $(deno info --json | jq -r .modulesCache)
      echo "deno version : ${pkgs.deno.version}"
      mkdir -p $out/bin
      ${compileCmd} --output=$out/bin/${bin} $src/${entrypoint}
      echo "COMPILE FINISHED"
    '';
    dontInstall = true;
    #installPhase = ''
      #mkdir -p $out/bin
      #cp "${bin}" "$out/bin/"
    #'';
  }
