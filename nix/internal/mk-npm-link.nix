{
  pkgs,
  lib,
  stdenv,
  linkFarm,
  writeText,
  deno2nix,
  ...
}:
let
  inherit (builtins) baseNameOf replaceStrings toJSON hashFile;
  inherit (lib) flatten mapAttrsToList importJSON;
  inherit (lib.strings) sanitizeDerivationName;

  # parse org from package name, either "@org/pkg@version" or "pkg@version"
  packageOrg = parts: if (lib.length parts) == 1 then "-" else (lib.head parts);
  registry = "registry.npmjs.org";

  packageComponents = package: rec {
    # deno.lock may contain an underscore after which additional pinned deps
    # appear, which we can ignore since all dependencies are captured individually
    # e.g.
    # "npm": {
    #   "specifiers": {
    #     "@aserto/aserto-node@0.23.0": "@aserto/aserto-node@0.23.0_@bufbuild+protobuf@1.3.1",
    #   }
    # }
    # Even then we also need to handle packages that _do_ have underscores in the name, e.g.
    # string_decoder@1.3.0
    packageWithDepsMeta = (lib.length (lib.splitString "_" package)) > 1 && (lib.length (lib.splitString "@" package)) > 2;
    parts = if packageWithDepsMeta
      then lib.splitString "/" (lib.head (lib.splitString "_" package))
      else lib.splitString "/" package;
    org = packageOrg parts;
    pkg = lib.last parts;
    name = lib.head (lib.splitString "@" pkg);
    version = lib.last (lib.splitString "@" pkg);
    packagePath = if org == "-" then name else "${org}/${name}";
    path = lib.concatStringsSep "/" [
      registry
      # lib.optional
      packagePath
      version
    ];
    url = lib.concatStringsSep "/" [
      registry
      (if org == "-" then name else "${org}/${name}")
      "-"
      "${name}-${version}.tgz"
    ];
  };

  packageToPath = package: (packageComponents package).path;
  packageToUrl = package: (packageComponents package).url;

in
  lockfile: (
    linkFarm "npm" (flatten (
      mapAttrsToList
      (
        package: attributes:
        let
          components = packageComponents package;
          # unlike builtins.fetchurl, pkgs.fetchurl accepts a sha512 SRI.
          # fetchzip would recursively hash the files in the tarball,
          # whereas the provided integrity sha is of the tarball itself.
          src = pkgs.fetchurl rec {
            url = packageToUrl package;
            hash = attributes.integrity;
            recursiveHash = false;
            name = sanitizeDerivationName (baseNameOf (packageToUrl package));
          };
        in
        [
          # the package source
          {
            name = packageToPath package;
            path = stdenv.mkDerivation {
              inherit src;
              pname = "npm-${components.name}";
              version = components.version;
              dontConfigure = true;
              dontBuild = true;
              dontPatch = true;
              installPhase = ''
                mkdir -p $out
                tar --no-same-owner --no-same-permissions \
                  --strip-components=1 \
                  -xzf $src \
                  -C $out
              '';
            };
          }
          # since we don't have a shasum for downloading the registry.json, make a fake one
          {
            name = lib.concatStringsSep "/" [registry components.packagePath "registry.json" ];
            path = writeText "npm-${components.name}-registry.json" (toJSON {
              name = components.name;
              dist-tags.latest = components.version;
              versions.${components.version} = {
                version = components.version;
                dist = {
                  # deno requires the sha1 in the registry.json even though it's not in the lockfile
                  shasum = hashFile "sha1" src;
                  tarball = packageToUrl package;
                  integrity = attributes.integrity;
                };
                # TODO: unsure about the rest of these fields
                dependencies = attributes.dependencies;
                optionalDependencies = {};
                peerDependencies = {};
                peerDependenciesMeta = {};
                bin = "";
                os = [];
                cpu = [];
              };
            });
          }
        ]
      )
      (importJSON lockfile).npm.packages
    ))
  )
