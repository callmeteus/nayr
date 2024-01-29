import { hideBin } from "yargs/helpers";
import yargs from "yargs/yargs";

import { CommandProcessor } from "./core/CommandProcessor";

const app = new CommandProcessor();

async function perform() {
    const args = await yargs(
        hideBin(process.argv)
    )
        .command("link [package]", "Links a new package", (yargs) => {
            return yargs
                .positional("package", {
                    type: "string",
                    describe: "The package to be linked. If none is given, will link try creating a link to the current package.",
                    requiresArg: false
                })
                .option("global", {
                    alias: "g",
                    type: "boolean",
                    describe: "If it's a global operation",
                    requiresArg: false
                })
        })

        .command("unlink [package]", "Unlinks an existing package", (yargs) => {
            return yargs
                .positional("package", {
                    type: "string",
                    describe: "The package to be unlinked. If none is given, will try to globally unlink the current package.",
                    requiresArg: false
                })
                .option("global", {
                    alias: "g",
                    type: "boolean",
                    describe: "If it's a global operation",
                    requiresArg: false
                })
                .option("force", {
                    alias: "f",
                    type: "boolean",
                    describe: "Will force deleting the symlink from the original package manager folder.",
                    requiresArg: false
                });
        })

        .command("reset-global-links", "Will delete all existing global links.\nWARNING: this may break entire applications if used incorrectly.", (yargs) => {
            return yargs
                .option("onlyBroken", {
                    type: "boolean",
                    alias: ["b", "only-broken"],
                    default: false,
                    describe: "Will delete only broken symlinks."
                });
        })

        .command("mklink [pattern]", "Creates links for a given glob pattern.", (yargs) => {
            return yargs
                .positional("pattern", {
                    type: "string",
                    requiresArg: true,
                    describe: "The glob pattern to find for directories with projects to be linked."
                })
                .option("depth", {
                    type: "number",
                    alias: ["d"],
                    requiresArg: false,
                    describe: "The depth to search for folder by using the pattern."
                })
        })

        .command("global-hook [action]", "Installs a global hook into yarn / npm. It will act like a `postinstall` lifecycle event.", (yargs) => {
            return yargs
                .positional("action", {
                    type: "string",
                    choices: ["install", "uninstall"]
                });
        })

        .command("*", "Will try to link all linked packages", (yargs) => {
            return yargs
                .option("ignoreGlobalLinks", {
                    alias: ["ignore-global", "ignore-global-links", "igl"],
                    type: "boolean",
                    describe: "If can ignore all global links",
                    requiresArg: false,
                    default: false
                })
                .option("ignoreFileLinks", {
                    alias: ["ignore-file", "ignore-file-links", "ifl"],
                    type: "boolean",
                    describe: "If can ignore all \"file:\" links",
                    requiresArg: false,
                    default: false
                });
        })

        .option("verbose", {
            alias: "v",
            type: "boolean",
            describe: "Enables verbose logging",
            requiresArg: false
        })

        .option("headless", {
            type: "boolean",
            describe: "Enables headless mode",
            default: false
        })

        .global(["verbose", "headless"])

        .parse();

    const cmd = args._[0];

    app.setOptions({
        verbose: args.verbose,
        headless: args.headless
    });

    app.process(cmd as string, args);
}

perform();