{
  description = "MidTerm - web-based terminal multiplexer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      version = builtins.fromJSON (builtins.readFile ./src/version.json);
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # Pre-fetch npm dependencies for the frontend build
          frontendNpmDeps = pkgs.fetchNpmDeps {
            src = ./src/Ai.Tlbx.MidTerm;
            hash = "sha256-jH+JFSbTJRPqJVDgDDJViJs/Cg8tXMwYT/Ys/+HZxcQ=";
          };

          # Build the frontend assets (TypeScript bundle + static assets)
          frontend = pkgs.stdenv.mkDerivation {
            pname = "midterm-frontend";
            version = version.web;

            src = ./src/Ai.Tlbx.MidTerm;

            nativeBuildInputs = with pkgs; [
              nodejs
              npmHooks.npmConfigHook
              brotli
            ];

            npmDeps = frontendNpmDeps;

            # Skip TypeScript type-checking and ESLint in Nix build (source is already checked)
            buildPhase = ''
              runHook preBuild

              export HOME=$TMPDIR

              VERSION="${version.web}"
              # Compute a static asset fingerprint
              ASSET_VERSION=$(find src/static src/ts openapi -type f | sort | xargs sha256sum | sha256sum | cut -c1-12)

              # Bundle with esbuild
              mkdir -p wwwroot/js wwwroot/css wwwroot/fonts wwwroot/img wwwroot/openapi wwwroot/swagger wwwroot/locales

              npx esbuild src/ts/main.ts \
                --bundle --minify \
                --outfile=wwwroot/js/terminal.min.js \
                --target=es2020 \
                "--define:BUILD_VERSION='$VERSION'" \
                "--define:BUILD_ASSET_VERSION='$ASSET_VERSION'"

              # Copy static assets
              cp -r src/static/fonts/* wwwroot/fonts/
              cp -r src/static/img/* wwwroot/img/
              cp src/static/favicon/favicon.ico wwwroot/
              cp src/static/favicon/*.png wwwroot/

              # Copy and process text assets (replace asset version placeholder)
              for f in src/static/*.html src/static/*.webmanifest src/static/*.txt; do
                [ -f "$f" ] && sed "s/__MIDTERM_ASSET_VERSION__/$ASSET_VERSION/g" "$f" > "wwwroot/$(basename "$f")"
              done

              # CSS: minify with esbuild
              for f in src/static/css/*.css; do
                [ -f "$f" ] && npx esbuild "$f" --minify --outfile="wwwroot/css/$(basename "$f")"
                # Replace asset version placeholder in minified CSS
                sed -i "s/__MIDTERM_ASSET_VERSION__/$ASSET_VERSION/g" "wwwroot/css/$(basename "$f")"
              done

              # Locale files
              if [ -d src/static/locales ]; then
                for f in src/static/locales/*.json; do
                  [ -f "$f" ] && sed "s/__MIDTERM_ASSET_VERSION__/$ASSET_VERSION/g" "$f" > "wwwroot/locales/$(basename "$f")"
                done
              fi

              # Additional JS files (audio worklets etc.)
              if [ -d src/static/js ]; then
                for f in src/static/js/*.js; do
                  [ -f "$f" ] && sed "s/__MIDTERM_ASSET_VERSION__/$ASSET_VERSION/g" "$f" > "wwwroot/js/$(basename "$f")"
                done
              fi

              # OpenAPI spec
              cp openapi/openapi.json wwwroot/openapi/

              # Swagger UI assets from node_modules
              cp node_modules/swagger-ui-dist/swagger-ui.css wwwroot/swagger/
              cp node_modules/swagger-ui-dist/swagger-ui-bundle.js wwwroot/swagger/
              cp node_modules/swagger-ui-dist/swagger-ui-standalone-preset.js wwwroot/swagger/
              cp src/static/swagger/index.html wwwroot/swagger/
              cp src/static/swagger/swagger-initializer.js wwwroot/swagger/

              # html2canvas vendor library
              if [ -f node_modules/html2canvas/dist/html2canvas.min.js ]; then
                cp node_modules/html2canvas/dist/html2canvas.min.js wwwroot/js/
              fi

              # Brotli compress all text assets for publish embedding
              find wwwroot -type f \( \
                -name '*.html' -o -name '*.css' -o -name '*.js' -o -name '*.json' \
                -o -name '*.webmanifest' -o -name '*.txt' -o -name '*.map' \
              \) | while read -r file; do
                brotli --best -o "$file.br" "$file"
                rm "$file"
              done

              # Compress select binary assets that benefit from Brotli
              for f in wwwroot/fonts/Terminus.woff2 wwwroot/fonts/midFont.woff wwwroot/favicon.ico; do
                if [ -f "$f" ]; then
                  brotli --best -o "$f.br" "$f"
                  rm "$f"
                fi
              done

              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              cp -r wwwroot $out
              runHook postInstall
            '';
          };
        in
        {
          default = pkgs.buildDotnetModule {
            pname = "midterm";
            version = version.web;

            src = ./.;

            projectFile = [
              "src/Ai.Tlbx.MidTerm/Ai.Tlbx.MidTerm.csproj"
              "src/Ai.Tlbx.MidTerm.TtyHost/Ai.Tlbx.MidTerm.TtyHost.csproj"
            ];

            nugetDeps = ./deps.json;

            dotnet-sdk = pkgs.dotnetCorePackages.sdk_10_0;
            dotnet-runtime = null; # AOT - no runtime needed

            selfContainedBuild = true;

            nativeBuildInputs = with pkgs; [
              nodejs # needed by csproj ReadVersionJson target
              clang
              brotli
            ];

            # Link frontend assets into the source tree before dotnet publish
            preBuild = ''
              cp -r ${frontend} src/Ai.Tlbx.MidTerm/wwwroot
            '';

            dotnetFlags = [
              "/p:SkipFrontendBuild=true"
            ];

            dotnetPublishFlags = [
              "/p:IsPublishing=true"
              "/p:ContinuousIntegrationBuild=true"
            ];

            executables = [
              "mt"
              "mthost"
            ];

            meta = with pkgs.lib; {
              description = "Web-based terminal multiplexer - run AI coding agents and local tools, access from any browser";
              homepage = "https://github.com/tlbx-ai/MidTerm";
              license = licenses.agpl3Only;
              mainProgram = "mt";
              platforms = [
                "x86_64-linux"
                "aarch64-linux"
              ];
            };
          };
        }
      );
    };
}
