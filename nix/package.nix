{ bash, bun, bun2nix, installShellFiles, lib, makeWrapper, symlinkJoin }:

let
  manifest = builtins.fromJSON (builtins.readFile ./package-manifest.json);
  packageVersion =
    manifest.package.version
    + lib.optionalString (manifest.package ? packageRevision) "-r${toString manifest.package.packageRevision}";
  licenseMap = {
    "MIT" = lib.licenses.mit;
    "Apache-2.0" = lib.licenses.asl20;
    "SEE LICENSE IN README.md" = lib.licenses.unfree;
  };
  resolvedLicense =
    if builtins.hasAttr manifest.meta.licenseSpdx licenseMap
    then licenseMap.${manifest.meta.licenseSpdx}
    else lib.licenses.unfree;
  aliasOutputs = manifest.binary.aliases or [ ];
  aliasWrappers = lib.concatMapStrings
    (
      alias:
      ''
        makeWrapper "$out/bin/${manifest.binary.name}" "$out/bin/${alias}"
      ''
    )
    aliasOutputs;
  aliasOutputLinks = lib.concatMapStrings
    (
      alias:
      ''
        mkdir -p "${"$" + alias}/bin"
        cat > "${"$" + alias}/bin/${alias}" <<EOF
#!${lib.getExe bash}
exec "$out/bin/${manifest.binary.name}" "\$@"
EOF
        chmod +x "${"$" + alias}/bin/${alias}"
      ''
    )
    aliasOutputs;
  overstoryPatch = lib.optionalString (manifest.package.repo == "overstory-cli") ''
    overstoryNodeModules="$out/share/${manifest.package.repo}/node_modules"
    overstoryPiRuntime="$(find "$overstoryNodeModules" -path '*@os-eco/overstory-cli/src/runtimes/pi.ts' | head -n 1)"
    overstoryTmux="$(find "$overstoryNodeModules" -path '*@os-eco/overstory-cli/src/worktree/tmux.ts' | head -n 1)"
    overstoryCoordinator="$(find "$overstoryNodeModules" -path '*@os-eco/overstory-cli/src/commands/coordinator.ts' | head -n 1)"
    overstoryMonitor="$(find "$overstoryNodeModules" -path '*@os-eco/overstory-cli/src/commands/monitor.ts' | head -n 1)"
    overstoryInspect="$(find "$overstoryNodeModules" -path '*@os-eco/overstory-cli/src/commands/inspect.ts' | head -n 1)"
    overstoryIndex="$(find "$overstoryNodeModules" -path '*@os-eco/overstory-cli/src/index.ts' | head -n 1)"
    overstoryCommandsDir="$(find "$overstoryNodeModules" -path '*@os-eco/overstory-cli/src/commands' -type d | head -n 1)"
    overstorySessions="$overstoryCommandsDir/sessions.ts"

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

    if [ -f "$overstoryTmux" ]; then
      oldTmuxHelpers=$(cat <<'EOF'
import { dirname, resolve } from "node:path";
import { AgentError } from "../errors.ts";
import type { ReadyState } from "../runtimes/types.ts";

/**
 * Detect the directory containing the overstory binary.
EOF
      )
      newTmuxHelpers=$(cat <<'EOF'
import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { AgentError } from "../errors.ts";
import type { ReadyState } from "../runtimes/types.ts";

const OVERSTORY_DIRNAME = ".overstory";
const TMUX_SOCKET_FILENAME = "tmux.sock";
const TMUX_CONFIG_FILENAME = "tmux.conf";

function findOverstoryDir(startDir: string = process.cwd()): string | null {
	let current = resolve(startDir);

	while (true) {
		const candidate = join(current, OVERSTORY_DIRNAME);
		if (existsSync(candidate)) {
			return candidate;
		}
		const parent = dirname(current);
		if (parent === current) {
			return null;
		}
		current = parent;
	}
}

function buildProjectTmuxCommand(
	args: string[],
	cwd?: string,
	includeConfig: boolean = false,
): string[] {
	const cmd = ["tmux"];
	const overstoryDir = findOverstoryDir(cwd ?? process.cwd());

	if (overstoryDir) {
		cmd.push("-S", join(overstoryDir, TMUX_SOCKET_FILENAME));
		if (includeConfig) {
			const configPath = join(overstoryDir, TMUX_CONFIG_FILENAME);
			if (existsSync(configPath)) {
				cmd.push("-f", configPath);
			}
		}
	}

	cmd.push(...args);
	return cmd;
}

async function runProjectTmuxCommand(
	args: string[],
	cwd?: string,
	includeConfig: boolean = false,
): Promise<{ stdout: string; stderr: string; exitCode: number }> {
	return runCommand(buildProjectTmuxCommand(args, cwd, includeConfig), cwd);
}

export function buildProjectTmuxCliArgs(
	args: string[],
	cwd?: string,
	includeConfig: boolean = false,
): string[] {
	return buildProjectTmuxCommand(args, cwd, includeConfig);
}

/**
 * Detect the directory containing the overstory binary.
EOF
      )
      oldCreateSession=$(cat <<'EOF'
	const { exitCode, stderr } = await runCommand(
		["tmux", "new-session", "-d", "-s", name, "-c", cwd, wrappedCommand],
		cwd,
	);
EOF
      )
      newCreateSession=$(cat <<'EOF'
	const { exitCode, stderr } = await runProjectTmuxCommand(
		["new-session", "-d", "-s", name, "-c", cwd, wrappedCommand],
		cwd,
		true,
	);
EOF
      )
      oldKillMissing=$(cat <<'EOF'
		if (stderr.includes("session not found") || stderr.includes("can't find session")) {
EOF
      )
      newKillMissing=$(cat <<'EOF'
		if (
			stderr.includes("session not found") ||
			stderr.includes("find session") ||
			stderr.includes("no server running")
		) {
EOF
      )
      substituteInPlace "$overstoryTmux" \
        --replace-fail "$oldTmuxHelpers" "$newTmuxHelpers" \
        --replace-fail "$oldCreateSession" "$newCreateSession" \
        --replace-fail 'pidResult = await runCommand(["tmux", "list-panes", "-t", name, "-F", "#{pane_pid}"]);' \
                         'pidResult = await runProjectTmuxCommand(["list-panes", "-t", name, "-F", "#{pane_pid}"], cwd);' \
        --replace-fail '	const { exitCode, stdout, stderr } = await runCommand([
		"tmux",
		"list-sessions",
		"-F",
		"#{session_name}:#{pid}",
	]);' \
                         '	const { exitCode, stdout, stderr } = await runProjectTmuxCommand([
		"list-sessions",
		"-F",
		"#{session_name}:#{pid}",
	]);' \
        --replace-fail '	const { exitCode, stdout } = await runCommand([
		"tmux",
		"display-message",
		"-p",
		"-t",
		name,
		"#{pane_pid}",
	]);' \
                         '	const { exitCode, stdout } = await runProjectTmuxCommand([
		"display-message",
		"-p",
		"-t",
		name,
		"#{pane_pid}",
	]);' \
        --replace-fail '	const { exitCode, stderr } = await runCommand(["tmux", "kill-session", "-t", name]);' \
                         '	const { exitCode, stderr } = await runProjectTmuxCommand(["kill-session", "-t", name]);' \
        --replace-fail "$oldKillMissing" "$newKillMissing" \
        --replace-fail '	const { exitCode } = await runCommand(["tmux", "has-session", "-t", name]);' \
                         '	const { exitCode } = await runProjectTmuxCommand(["has-session", "-t", name]);' \
        --replace-fail '	const { exitCode, stderr } = await runCommand(["tmux", "has-session", "-t", name]);' \
                         '	const { exitCode, stderr } = await runProjectTmuxCommand(["has-session", "-t", name]);' \
        --replace-fail '	const { exitCode, stdout } = await runCommand([
		"tmux",
		"capture-pane",
		"-t",
		name,
		"-p",
		"-S",
		`-''${lines}`,
	]);' \
                         '	const { exitCode, stdout } = await runProjectTmuxCommand([
		"capture-pane",
		"-t",
		name,
		"-p",
		"-S",
		`-''${lines}`,
	]);' \
        --replace-fail '		const { exitCode, stderr } = await runCommand([
			"tmux",
			"send-keys",
			"-t",
			name,
			flatKeys,
			"Enter",
		]);' \
                         '		const { exitCode, stderr } = await runProjectTmuxCommand([
			"send-keys",
			"-t",
			name,
			flatKeys,
			"Enter",
		]);' \
        --replace-fail '	const { exitCode, stderr } = await runCommand(["tmux", "send-keys", "-t", name, flatKeys]);' \
                         '	const { exitCode, stderr } = await runProjectTmuxCommand(["send-keys", "-t", name, flatKeys]);'
    fi

    if [ -f "$overstoryCoordinator" ]; then
      substituteInPlace "$overstoryCoordinator" \
        --replace-fail '	waitForTuiReady,
} from "../worktree/tmux.ts";' \
                         '	waitForTuiReady,
	buildProjectTmuxCliArgs,
} from "../worktree/tmux.ts";' \
        --replace-fail '			Bun.spawnSync(["tmux", "attach-session", "-t", tmuxSession], {' \
                         '			Bun.spawnSync(buildProjectTmuxCliArgs(["attach-session", "-t", tmuxSession], projectRoot), {'
    fi

    if [ -f "$overstoryMonitor" ]; then
      substituteInPlace "$overstoryMonitor" \
        --replace-fail 'import { createSession, isSessionAlive, killSession, sendKeys } from "../worktree/tmux.ts";' \
                         'import { buildProjectTmuxCliArgs, createSession, isSessionAlive, killSession, sendKeys } from "../worktree/tmux.ts";' \
        --replace-fail '			Bun.spawnSync(["tmux", "attach-session", "-t", tmuxSession], {' \
                         '			Bun.spawnSync(buildProjectTmuxCliArgs(["attach-session", "-t", tmuxSession], projectRoot), {'
    fi

    if [ -f "$overstoryInspect" ]; then
      substituteInPlace "$overstoryInspect" \
        --replace-fail 'import { openSessionStore } from "../sessions/compat.ts";' \
                         'import { openSessionStore } from "../sessions/compat.ts";
import { buildProjectTmuxCliArgs } from "../worktree/tmux.ts";' \
        --replace-fail '	const overstoryDir = join(root, ".overstory");' \
                         '	const projectRoot = root;
	const overstoryDir = join(root, ".overstory");' \
        --replace-fail '	const root = config.project.root;' \
                         '	const projectRoot = config.project.root;
	const root = projectRoot;' \
        --replace-fail 'async function captureTmux(sessionName: string, lines: number): Promise<string | null> {' \
                         'async function captureTmux(sessionName: string, lines: number, projectRoot: string): Promise<string | null> {' \
        --replace-fail '		const proc = Bun.spawn(["tmux", "capture-pane", "-t", sessionName, "-p", "-S", `-''${lines}`], {' \
                         '		const proc = Bun.spawn(buildProjectTmuxCliArgs(["capture-pane", "-t", sessionName, "-p", "-S", `-''${lines}`], projectRoot), {' \
        --replace-fail '			tmuxOutput = await captureTmux(session.tmuxSession, lines);' \
                         '			tmuxOutput = await captureTmux(session.tmuxSession, lines, projectRoot);'
    fi

    if [ -n "$overstoryCommandsDir" ] && [ ! -f "$overstorySessions" ]; then
      mkdir -p "$overstoryCommandsDir"
      cat > "$overstorySessions" <<'EOF'
/**
 * CLI command: ov sessions <subcommand>
 *
 * Manage overstory-managed tmux sessions through the project's isolated
 * tmux socket. This provides a user-facing roof over list/attach/kill
 * without requiring direct `tmux -S ...` usage.
 */

import { join } from "node:path";
import { Command } from "commander";
import { loadConfig } from "../config.ts";
import { jsonOutput } from "../json.ts";
import { accent, printError, printHint } from "../logging/color.ts";
import { openSessionStore } from "../sessions/compat.ts";
import type { AgentSession } from "../types.ts";
import {
	buildProjectTmuxCliArgs,
	getCurrentSessionName,
	isSessionAlive,
	killSession,
} from "../worktree/tmux.ts";

function attachableSessions(sessions: readonly AgentSession[]): AgentSession[] {
	return sessions.filter((session) => session.tmuxSession.trim().length > 0);
}

function listSessionHints(sessions: readonly AgentSession[]): void {
	if (sessions.length === 0) {
		printHint("No attachable tmux sessions found.");
		return;
	}

	printHint("Attachable sessions:");
	for (const session of sessions) {
		printHint(
			`  ''${session.agentName} -> ''${session.tmuxSession} (''${session.capability}, ''${session.state})`,
		);
	}
}

function resolveTargetSession(
	sessions: readonly AgentSession[],
	requested?: string,
): { session: AgentSession | null; reason?: "ambiguous" | "missing" } {
	if (requested) {
		const match =
			sessions.find((session) => session.agentName === requested) ??
			sessions.find((session) => session.tmuxSession === requested) ??
			null;
		return { session: match, reason: match ? undefined : "missing" };
	}

	const coordinator = sessions.find((session) => session.agentName === "coordinator");
	if (coordinator) {
		return { session: coordinator };
	}

	const monitor = sessions.find((session) => session.agentName === "monitor");
	if (monitor) {
		return { session: monitor };
	}

	if (sessions.length === 1) {
		return { session: sessions[0] ?? null };
	}

	return { session: null, reason: sessions.length === 0 ? "missing" : "ambiguous" };
}

async function loadAttachableSessions(projectRoot: string, includeAll = false): Promise<AgentSession[]> {
	const overstoryDir = join(projectRoot, ".overstory");
	const { store } = openSessionStore(overstoryDir);
	try {
		return attachableSessions(includeAll ? store.getAll() : store.getActive());
	} finally {
		store.close();
	}
}

async function attachToSession(
	projectRoot: string,
	sessions: readonly AgentSession[],
	agent: string | undefined,
	json: boolean,
): Promise<void> {
	const resolved = resolveTargetSession(sessions, agent);

	if (!resolved.session) {
		if (json) {
			jsonOutput("sessions attach", {
				ok: false,
				reason: resolved.reason ?? "missing",
				requested: agent ?? null,
				sessions: sessions.map((session) => ({
					agentName: session.agentName,
					tmuxSession: session.tmuxSession,
					capability: session.capability,
					state: session.state,
				})),
			});
			process.exitCode = 1;
			return;
		}

		if (resolved.reason === "ambiguous") {
			printError("Multiple attachable sessions found", "pass an agent name");
		} else {
			printError("No matching attachable session found", agent);
		}
		listSessionHints(sessions);
		process.exitCode = 1;
		return;
	}

	const alive = await isSessionAlive(resolved.session.tmuxSession);
	if (!alive) {
		if (json) {
			jsonOutput("sessions attach", {
				ok: false,
				reason: "dead",
				agentName: resolved.session.agentName,
				tmuxSession: resolved.session.tmuxSession,
			});
			process.exitCode = 1;
			return;
		}

		printError(
			"Tmux session is not alive",
			`''${resolved.session.agentName} -> ''${resolved.session.tmuxSession}`,
		);
		process.exitCode = 1;
		return;
	}

	if (json) {
		jsonOutput("sessions attach", {
			ok: true,
			agentName: resolved.session.agentName,
			tmuxSession: resolved.session.tmuxSession,
		});
		return;
	}

	printHint(
		`Attaching to ''${accent(resolved.session.agentName)} (''${resolved.session.tmuxSession})`,
	);
	Bun.spawnSync(
		buildProjectTmuxCliArgs(["attach-session", "-t", resolved.session.tmuxSession], projectRoot),
		{
			stdio: ["inherit", "inherit", "inherit"],
		},
	);
}

export function createSessionsCommand(): Command {
	const cmd = new Command("sessions").description("Manage isolated overstory tmux sessions");

	cmd
		.command("list")
		.alias("ls")
		.description("List overstory-managed tmux sessions")
		.option("--all", "Include completed and zombie sessions")
		.option("--json", "Output as JSON")
		.action(async (opts: { all?: boolean; json?: boolean }) => {
			const cwd = process.cwd();
			const config = await loadConfig(cwd);
			const projectRoot = config.project.root;
			const sessions = await loadAttachableSessions(projectRoot, opts.all ?? false);
			const rows = await Promise.all(
				sessions.map(async (session) => ({
					agentName: session.agentName,
					tmuxSession: session.tmuxSession,
					capability: session.capability,
					state: session.state,
					alive: await isSessionAlive(session.tmuxSession),
				})),
			);

			if (opts.json) {
				jsonOutput("sessions list", { sessions: rows });
				return;
			}

			if (rows.length === 0) {
				printHint("No attachable tmux sessions found.");
				return;
			}

			for (const row of rows) {
					printHint(
						`''${row.agentName} -> ''${row.tmuxSession} (''${row.capability}, ''${row.state}, ''${row.alive ? "alive" : "dead"})`,
					);
			}
		});

	cmd
		.command("attach")
		.description("Attach to an active overstory tmux session")
		.argument("[agent]", "Agent name or tmux session name")
		.option("--json", "Output as JSON")
		.action(async (agent: string | undefined, opts: { json?: boolean }) => {
			const cwd = process.cwd();
			const config = await loadConfig(cwd);
			const projectRoot = config.project.root;
			const sessions = await loadAttachableSessions(projectRoot, false);
			await attachToSession(projectRoot, sessions, agent, opts.json ?? false);
		});

	cmd
		.command("kill")
		.description("Kill an overstory tmux session by agent or session name")
		.argument("<agent>", "Agent name or tmux session name")
		.option("--json", "Output as JSON")
		.action(async (agent: string, opts: { json?: boolean }) => {
			const cwd = process.cwd();
			const config = await loadConfig(cwd);
			const projectRoot = config.project.root;
			const sessions = await loadAttachableSessions(projectRoot, true);
			const resolved = resolveTargetSession(sessions, agent);

			if (!resolved.session) {
				if (opts.json) {
					jsonOutput("sessions kill", {
						ok: false,
						reason: resolved.reason ?? "missing",
						requested: agent,
					});
				} else {
					printError("No matching attachable session found", agent);
				}
				process.exitCode = 1;
				return;
			}

			await killSession(resolved.session.tmuxSession);
			if (opts.json) {
				jsonOutput("sessions kill", {
					ok: true,
					agentName: resolved.session.agentName,
					tmuxSession: resolved.session.tmuxSession,
				});
			} else {
				printHint(`Killed ''${resolved.session.agentName} (''${resolved.session.tmuxSession})`);
			}
		});

	cmd
		.command("current")
		.description("Print the current tmux session name when inside overstory tmux")
		.option("--json", "Output as JSON")
		.action(async (opts: { json?: boolean }) => {
			const sessionName = await getCurrentSessionName();
			if (opts.json) {
				jsonOutput("sessions current", { tmuxSession: sessionName });
				if (!sessionName) process.exitCode = 1;
				return;
			}
			if (!sessionName) {
				printError("Not running inside a tmux session");
				process.exitCode = 1;
				return;
			}
			process.stdout.write(`''${sessionName}\n`);
		});

	return cmd;
}
EOF
    fi

    if [ -f "$overstoryIndex" ]; then
      substituteInPlace "$overstoryIndex" \
        --replace-fail 'import { createAgentsCommand } from "./commands/agents.ts";' \
                         'import { createAgentsCommand } from "./commands/agents.ts";
import { createSessionsCommand } from "./commands/sessions.ts";' \
        --replace-fail 'const COMMANDS = [
	"agents",' \
                         'const COMMANDS = [
	"agents",
	"sessions",' \
        --replace-fail 'program.addCommand(createAgentsCommand());' \
                         'program.addCommand(createAgentsCommand());
program.addCommand(createSessionsCommand());'
    fi

    find "$overstoryNodeModules" \
      \( -path '*src/runtimes/pi-guards.ts' -o -path '*src/runtimes/pi-guards.test.ts' \) \
      -delete
  '';
  basePackage = bun2nix.writeBunApplication {
    pname = manifest.package.repo;
    version = packageVersion;
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
  pname = manifest.binary.name;
  version = packageVersion;
  name = "${manifest.binary.name}-${packageVersion}";
  outputs = [ "out" ] ++ aliasOutputs;
  paths = [ basePackage ];
  nativeBuildInputs = [
    installShellFiles
    makeWrapper
  ];
  postBuild = ''
    rm -rf "$out/bin"
    mkdir -p "$out/bin"
    entrypoint="$(find "${basePackage}/share/${manifest.package.repo}/node_modules" -path "*/node_modules/${manifest.package.npmName}/${manifest.binary.entrypoint}" | head -n 1)"
    cat > "$out/bin/${manifest.binary.name}" <<EOF
#!${lib.getExe bash}
exec ${lib.getExe' bun "bun"} "$entrypoint" "\$@"
EOF
    chmod +x "$out/bin/${manifest.binary.name}"
    ${aliasOutputLinks}
    bashCompletion="$TMPDIR/${manifest.binary.name}.bash"
    fishCompletion="$TMPDIR/${manifest.binary.name}.fish"
    zshCompletion="$TMPDIR/_${manifest.binary.name}"
    "$out/bin/${manifest.binary.name}" completions bash > "$bashCompletion"
    "$out/bin/${manifest.binary.name}" completions fish > "$fishCompletion"
    "$out/bin/${manifest.binary.name}" completions zsh > "$zshCompletion"
    installShellCompletion --cmd ${manifest.binary.name} \
      --bash "$bashCompletion" \
      --fish "$fishCompletion" \
      --zsh "$zshCompletion"
  '';
  meta = basePackage.meta;
}
