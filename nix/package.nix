{ bash, bun, bun2nix, lib, makeWrapper, symlinkJoin }:

let
  manifest = builtins.fromJSON (builtins.readFile ./package-manifest.json);
  licenseMap = {
    "MIT" = lib.licenses.mit;
    "Apache-2.0" = lib.licenses.asl20;
    "SEE LICENSE IN README.md" = lib.licenses.unfree;
  };
  resolvedLicense =
    if builtins.hasAttr manifest.meta.licenseSpdx licenseMap
    then licenseMap.${manifest.meta.licenseSpdx}
    else lib.licenses.unfree;
  aliasWrappers = lib.concatMapStrings
    (
      alias:
      ''
        makeWrapper "$out/bin/${manifest.binary.name}" "$out/bin/${alias}"
      ''
    )
    (manifest.binary.aliases or [ ]);
  overstoryPatch = lib.optionalString (manifest.package.repo == "overstory-cli") ''
    overstoryNodeModules="$out/share/${manifest.package.repo}/node_modules"
    overstoryPiRuntime="$(find "$overstoryNodeModules" -path '*@os-eco/overstory-cli/src/runtimes/pi.ts' | head -n 1)"

    if [ -f "$overstoryPiRuntime" ]; then
      oldGuardImport=$(cat <<'EOF'
import { generatePiGuardExtension } from "./pi-guards.ts";
EOF
      )
      oldGuardWrite=$(cat <<'EOF'
		// Always deploy Pi guard extension.
		const piExtDir = join(worktreePath, ".pi", "extensions");
		await mkdir(piExtDir, { recursive: true });
		await Bun.write(join(piExtDir, "overstory-guard.ts"), generatePiGuardExtension(hooks));

EOF
      )
      oldDetectReady=$(cat <<'EOF'
		const hasHeader = paneContent.includes("pi v");
		const hasStatusBar = /\d+\.\d+%\/\d+k/.test(paneContent);
EOF
      )
      newDetectReady=$(cat <<'EOF'
		const hasHeader = paneContent.includes("pi v");
		const isOsEcoReady = paneContent.includes("[OS-ECO:READY]");
		const hasStatusBar =
			isOsEcoReady || /\d+(?:\.\d+)?%\/\d+(?:\.\d+)?[kKmM]/.test(paneContent);
EOF
      )

      substituteInPlace "$overstoryPiRuntime" \
        --replace-fail "$oldGuardImport" "" \
        --replace-fail "$oldGuardWrite" "" \
        --replace-fail "$oldDetectReady" "$newDetectReady"
    fi

    find "$overstoryNodeModules" \
      \( -path '*src/runtimes/pi-guards.ts' -o -path '*src/runtimes/pi-guards.test.ts' \) \
      -delete
  '';
  basePackage = bun2nix.writeBunApplication {
    pname = manifest.package.repo;
    version = manifest.package.version;
    packageJson = ../package.json;
    src = lib.cleanSource ../.;
    dontUseBunBuild = true;
    dontUseBunCheck = true;
    startScript = ''
      bunx ${manifest.binary.upstreamName or manifest.binary.name} "$@"
    '';
    bunDeps = bun2nix.fetchBunDeps {
      bunNix = ../bun.nix;
    };
    postInstall = ''
      ${overstoryPatch}
    '';
    meta = with lib; {
      description = manifest.meta.description;
      homepage = manifest.meta.homepage;
      license = resolvedLicense;
      mainProgram = manifest.binary.name;
      platforms = platforms.linux ++ platforms.darwin;
      broken = manifest.stubbed || !(builtins.pathExists ../bun.nix);
    };
  };
in
symlinkJoin {
  name = "${manifest.binary.name}-${manifest.package.version}";
  paths = [ basePackage ];
  nativeBuildInputs = [ makeWrapper ];
  postBuild = ''
    rm -rf "$out/bin"
    mkdir -p "$out/bin"
    entrypoint="$(find "${basePackage}/share/${manifest.package.repo}/node_modules" -path "*/node_modules/${manifest.package.npmName}/${manifest.binary.entrypoint}" | head -n 1)"
    cat > "$out/bin/${manifest.binary.name}" <<EOF
#!${lib.getExe bash}
exec ${lib.getExe' bun "bun"} "$entrypoint" "\$@"
EOF
    chmod +x "$out/bin/${manifest.binary.name}"
    ${aliasWrappers}
  '';
  meta = basePackage.meta;
}
