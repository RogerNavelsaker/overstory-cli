{ bun2nix, lib, makeWrapper, symlinkJoin }:

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
  allowedBinPattern = lib.concatStringsSep "|" ([ manifest.binary.name ] ++ (manifest.binary.aliases or [ ]));
  aliasWrappers = lib.concatMapStrings
    (
      alias:
      ''
        makeWrapper "$out/bin/${manifest.binary.name}" "$out/bin/${alias}"
      ''
    )
    (manifest.binary.aliases or [ ]);
  pruneBins = ''
    for binPath in "$out/bin/"*; do
      [ -e "$binPath" ] || continue
      binName="$(basename "$binPath")"
      case "$binName" in
        ${allowedBinPattern}) ;;
        *) rm -f "$binPath" ;;
      esac
    done
  '';
  overstoryPatch = lib.optionalString (manifest.package.repo == "overstory-cli") ''
    overstoryNodeModules="$out/share/${manifest.package.repo}/node_modules"
    overstoryPiRuntime="$(find "$overstoryNodeModules" -path '*@os-eco/overstory-cli/src/runtimes/pi.ts' | head -n 1)"

    if [ -f "$overstoryPiRuntime" ]; then
      substituteInPlace "$overstoryPiRuntime" \
        --replace-fail 'import { generatePiGuardExtension } from "./pi-guards.ts";
' "" \
        --replace-fail '		// Always deploy Pi guard extension.
		const piExtDir = join(worktreePath, ".pi", "extensions");
		await mkdir(piExtDir, { recursive: true });
		await Bun.write(join(piExtDir, "overstory-guard.ts"), generatePiGuardExtension(hooks));

' ""
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
    makeWrapper "${basePackage}/bin/${manifest.package.repo}" "$out/bin/${manifest.binary.name}"
    ${aliasWrappers}
  '';
  meta = basePackage.meta;
}
