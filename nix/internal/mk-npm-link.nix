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
  # parse package name, either @org/pkg or pkg from the full (@org)?/pkg@version string
  packageToParts = package: lib.splitString "@" (lib.head (lib.splitString "_" package));
  parse = parts: if (lib.length parts) == 3 then "@" + builtins.elemAt parts 1 else (lib.head parts);
  packageName = package: parse (packageToParts package);
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
    inherit package;
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

  lockToPackages = lockfile:
    let
      lock = importJSON lockfile;
    in
    if (lock ? npm)
      then lock.npm.packages
      else if (lock ? packages) then
      lock.packages.npm
      else {};

  # This is where things get brittle...
  # Basically, anytime there are multiple dependencies on different versions of the same package,
  # only one of the `registry.json` files will get linked, and this json will not contain the other
  # version(s) of the package causing deno compile `--cached-only` to fail, complaining of a missing
  # package that's present in the lockfile.
  #
  # So we're going to introspect the lock file here, not knowing which version of this registry.json
  # we be linked, but making sure each one will include all versions present in the lock file so deno
  # will find all necessary versions that have already been linked by the linkfarm.
  otherVersionsRegistry = (lock: components:
  let
    packages = lockToPackages lock;
  in
  {
    name = packageName components.package;
    dist-tags.latest = components.version;
    versions = builtins.listToAttrs (
      map (package:
        let
          packageWithDepsMeta = (lib.length (lib.splitString "_" package)) > 1 && (lib.length (lib.splitString "@" package)) > 2;
          parts = if packageWithDepsMeta
            then lib.splitString "/" (lib.head (lib.splitString "_" package))
            else lib.splitString "/" package;
          pkg = lib.last parts;
          version = lib.last (lib.splitString "@" pkg);
        in
        {
          name = version;
          value = {
            version = version;
            dist = {
              # just put in a fake value
              shasum = "";
              tarball = packageToUrl package;
              integrity = packages.${package}.integrity;
            };
            dependencies = packages.${package}.dependencies;
            optionalDependencies = {};
            peerDependencies = {};
            peerDependenciesMeta = {};
            bin = "";
            os = [];
            cpu = [];
          };
        }
      )
      (
        lib.filter (v: (packageName v) == (packageName components.package))
          (lib.mapAttrsToList (k: v: k) packages)
      )
    );
  }
  );
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
            path = writeText "npm-${components.name}-registry.json" (toJSON (otherVersionsRegistry lockfile components));
            #(toJSON {
              #name = components.name;
              #dist-tags.latest = components.version;
              #versions = {
                #${components.version} = {
                  #version = components.version;
                  #dist = {
                    ## deno requires the sha1 in the registry.json even though it's not in the lockfile
                    #shasum = hashFile "sha1" src;
                    #tarball = packageToUrl package;
                    #integrity = attributes.integrity;
                  #};
                  ## TODO: unsure about the rest of these fields
                  #dependencies = attributes.dependencies;
                  #optionalDependencies = {};
                  #peerDependencies = {};
                  #peerDependenciesMeta = {};
                  #bin = "";
                  #os = [];
                  #cpu = [];
                #};
              #};
            #});
          }
        ]
      )
      (lockToPackages lockfile)
    ))
  )
