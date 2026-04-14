import * as path from "path";
import * as fs from "fs";
import { spawnSync } from "child_process";
import { glob } from "glob";
import { CommandProcessor } from "../CommandProcessor";
import { App } from "../App";
import { logger } from "../Logger";
import { processFileLinks } from "./processFileLinks";
import { processGlobalLinks } from "./processGlobalLinks";

/**
 * Spawns nayr in each workspace member directory so they get their own links.
 * Using a child process is the right approach here since App and Yarn.nodeModulesDir
 * are singletons keyed to process.cwd() at startup time.
 */
const processWorkspaces = async () => {
    const pkg = App.instance().packageJson as any;

    if (!pkg?.workspaces) {
        return;
    }

    const patterns: string[] = Array.isArray(pkg.workspaces)
        ? pkg.workspaces
        : pkg.workspaces.packages ?? [];

    if (!patterns.length) {
        return;
    }

    const cwd = process.cwd();
    const nayrBin = process.argv[1];

    // Build passthrough flags from current options
    const opts = CommandProcessor.instance.options;
    const flags: string[] = ["--headless"];

    if (opts.verbose) {
        flags.push("--verbose");
    }

    if (opts.ignoreGlobalLinks) {
        flags.push("--ignore-global-links");
    }

    if (opts.ignoreFileLinks) {
        flags.push("--ignore-file-links");
    }

    for (const pattern of patterns) {
        const matches = await glob(pattern, { cwd, absolute: true });

        for (const match of matches) {
            // Only descend into directories that have their own package.json
            if (!fs.existsSync(path.join(match, "package.json"))) {
                continue;
            }

            logger.info("processing workspace: %s", path.relative(cwd, match));

            spawnSync(process.execPath, [nayrBin, ...flags], {
                cwd: match,
                stdio: "inherit"
            });
        }
    }
};

/**
 * Perform all links based on configurations.
 */
export const performLinks = async () => {
    /*if (CommandProcessor.instance.config.rules) {
        for(const rule of this.config.rules) {
            if ("includes" in rule) {
                this.processIncludeRule(rule.includes);
            }
        }
    }*/

    // If isn't ignoring global links
    if (!CommandProcessor.instance.options.ignoreGlobalLinks) {
        await processGlobalLinks();
    }

    // If isn't ignoring global links
    if (!CommandProcessor.instance.options.ignoreFileLinks) {
        await processFileLinks();
    }

    // Descend into workspace members so each gets its own links
    await processWorkspaces();

    logger.info("all packages were linked sucessfully");
};