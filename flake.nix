{
  description = "webR development environment";

  # Flake inputs
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-23.05";
    nixpkg-flang-webr.url = "github:wch/flang-webr/main";
  };

  # Flake outputs
  outputs = { self, nixpkgs, nixpkg-flang-webr }:
    let
      allSystems =
        [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

      # Helper to provide system-specific attributes
      forAllSystems = f:
        nixpkgs.lib.genAttrs allSystems (system:
          f rec {
            pkgs = import nixpkgs { inherit system; };
            pkg-flang-webr = nixpkg-flang-webr.packages.${system}.default;

            # Get emscripten from the flang-webr package
            pkg-emscripten = builtins.head
              (builtins.filter (x: x.pname == "emscripten")
                pkg-flang-webr.propagatedNativeBuildInputs);

            # Cached npm dependencies specified by src/package-lock.json. During
            # development, whenever package-lock.json is updated, the hash needs
            # to be updated. To find the hash, run:
            #     cd src; prefetch-npm-deps package-lock.json
            srcNpmDeps = pkgs.fetchNpmDeps {
              src = "${self}/src";
              hash = "sha256-FvKuT6ComD2KKOpd4ucnoyqZJz3wZfR6nKYOCKTLgYM=";
            };

            inherit system;
          });

    in rec {
      packages = forAllSystems
        ({ pkgs, pkg-flang-webr, system, pkg-emscripten, srcNpmDeps, ... }: {
          default = pkgs.stdenv.mkDerivation {
            name = "webr";
            src = ./.;

            nativeBuildInputs = with pkgs; [
              pkg-flang-webr
              pkg-emscripten

              git
              cacert

              cmake
              gperf
              lzma
              pcre2
              quilt
              wget
              nodejs_18

              # Inputs for building R borrowed from:
              # https://github.com/NixOS/nixpkgs/blob/85f1ba3e/pkgs/applications/science/math/R/default.nix
              bzip2
              gfortran
              perl
              xz
              zlib
              icu
              bison
              which
              blas
              lapack
              curl
              tzdata

              pkg-config # For fontconfig
              sqlite # For proj
              glib # For pango
              unzip # For extracting font data
            ];

            # Copy files from flang-webr package to their correct location in
            # the build source dir. Make sure those directories are writable
            # because this build will write to some of the same directories.
            postUnpack = ''
              cp -R ${pkg-flang-webr}/webr/* $sourceRoot
              chmod -R u+w $sourceRoot
            '';

            # Need to call configure _without_ extra arguments that mkDerivation
            # would normally throw in.
            #
            # The cd src; npm config stuff is so that it writes an .npmrc file
            # in the src/ directory. Later `npm ci` will be run from that
            # directory. If .npmrc is not present in the working dir, then npm
            # will look for it in the home directory, which does not exist in a
            # build.
            configurePhase = ''
              ./configure

              cd src
              npm config set cache "${srcNpmDeps}" --location project
              npm config set offline true --location project
              npm config set progress false --location project
              cd ..

              if [ ! -d $(pwd)/.emscripten_cache-${pkg-emscripten.version} ]; then
                cp -R ${pkg-emscripten}/share/emscripten/cache/ $(pwd)/.emscripten_cache-${pkg-emscripten.version}
                chmod u+rwX -R $(pwd)/.emscripten_cache-${pkg-emscripten.version}
              fi
              export EM_CACHE=$(pwd)/.emscripten_cache-${pkg-emscripten.version}
              echo emscripten cache dir: $EM_CACHE
            '';

            buildPhase = ''
              make -j$NIX_BUILD_CORES
            '';

            installPhase = ''
              mkdir -p $out
              cp -r dist $out
            '';
          };
        });

      # Development environment output
      devShells = forAllSystems ({ pkgs, system, pkg-emscripten, ... }: {
        default = pkgs.mkShell {
          inputsFrom = [ packages.${system}.default ];

          packages = with pkgs; [
            prefetch-npm-deps
          ];

          # TODO: Add information on how to get the SHA256:
          # cd src; prefetch-npm-deps package-lock.json

          # This is a workaround for nix emscripten cache directory not being
          # writable. Borrowed from:
          # https://discourse.nixos.org/t/improving-an-emscripten-yarn-dev-shell-flake/33045
          # Issue at https://github.com/NixOS/nixpkgs/issues/139943
          #
          # Also note that `nix develop` must be run in the top-level directory
          # of the project; otherwise this script will create the cache dir
          # inside of the current working dir. Currently there isn't a way to
          # the top-level dir from within this file, but there is an open issue
          # for it. After that issue is fixed and the fixed version of nix is in
          # widespread use, we'll be able to use
          # https://github.com/NixOS/nix/issues/8034
          shellHook = ''
            if [ ! -d $(pwd)/.emscripten_cache-${pkg-emscripten.version} ]; then
              cp -R ${pkg-emscripten}/share/emscripten/cache/ $(pwd)/.emscripten_cache-${pkg-emscripten.version}
              chmod u+rwX -R $(pwd)/.emscripten_cache-${pkg-emscripten.version}
            fi
            export EM_CACHE=$(pwd)/.emscripten_cache-${pkg-emscripten.version}
            echo emscripten cache dir: $EM_CACHE
          '';
        };
      });
    };
}
