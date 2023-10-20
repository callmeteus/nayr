import { hideBin } from "yargs/helpers";
import yargs from "yargs/yargs";

import { App } from "./core/App";
import { logger } from "./core/Logger";

const app = new App();

async function perform() {
    const args = await yargs(
        hideBin(process.argv)
    )
        .command("link [package]", "Links a new package", (yargs) =>
            yargs
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
        )

        .command("unlink [package]", "Unlinks an existing package", (yargs) =>
            yargs
                .positional("package", {
                    type: "string",
                    describe: "The package to be unlinked. If none is given, will try to globally unlink the current package.",
                    requiresArg: false
                }))
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
                })

        .command("reset-global-links", "Will delete all existing global links.\nWARNING: this may break entire applications if used incorrectly.", (yargs) => 
            yargs
                .option("onlyBroken", {
                    type: "boolean",
                    alias: ["b", "only-broken"],
                    default: false,
                    describe: "Will delete only broken symlinks."
                }))

        .command("*", "Will try to link all linked packages", (yargs) =>
            yargs
                .option("ignoreGlobalLinks", {
                    alias: ["ignore-global", "ignore-global-links", "igl"],
                    type: "boolean",
                    describe: "If can ignore all global links",
                    requiresArg: false,
                    default: false
                })
        )

        .option("verbose", {
            alias: "v",
            type: "boolean",
            describe: "Enables verbose logging",
            requiresArg: false
        })

        .global(["verbose"])

        .parse();

    const cmd = args._[0];

    if (args.verbose) {
        logger.level = "silly";
    }

    switch(cmd) {
        case undefined:
            app.setConfig(args as any);
            app.performLinks();
        break;

        case "link":
            app.link(args as any);
        break;

        case "unlink":
            app.unlink(args as any);
        break;

        case "reset-global-links":
            app.resetGlobalLinks(args as any);
        break;
    }
}

perform();