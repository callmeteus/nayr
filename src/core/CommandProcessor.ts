import { glob } from "glob";
import { App, ILinkOptions } from "./App";

import * as path from "path";
import * as fs from "fs";

import colors from "colors";
import deepmerge from "deepmerge";

import { logger } from "./Logger";
import { Yarn } from "../helpers/Yarn";
import { exitWithError } from "../helpers/Process";
import { YarnDetourer } from "./YarnDetourer";

interface IOptions {
    ignoreGlobalLinks?: boolean;
    verbose?: boolean;
    headless?: boolean;
}

export class CommandProcessor {
    constructor(
        protected options: IOptions = {}
    ) {
        this.setOptions(options);
    }

    /**
     * Processes a single command.
     * @param cmd The command name.
     * @param args The command arguments.
     * @returns 
     */
    public process(cmd: string, args: any) {
        // If not headless, announce the software name and version
        if (!this.options.headless) {
            console.log(colors.bold("nayr v%s"), App.instance().version);
        }

        this.setOptions(args as any);

        switch(cmd) {
            case undefined:
                return this.performLinks();

            case "link":
                return this.link(args as any);
    
            case "mklink":
                return this.mklink(args as any);
    
            case "unlink":
                return this.unlink(args as any);
    
            case "reset-global-links":
                return this.resetGlobalLinks(args as any);

            case "global-hook": {
                const detour = new YarnDetourer();
                
                if (args.action === "install") {
                    return detour.detourAdd();
                } else {
                    return detour.detourRemove();
                }
            };
        }
    }

    /**
     * Merges the current options with new options.
     * @param options The options to be updated.
     */
    public setOptions(options: IOptions) {
        this.options = deepmerge(this.options, options);
        this.setup();
    }

    /**
     * Sets up some things that controls the application flow.
     */
    private setup() {
        logger.level = this.options.verbose ? "silly" : "info";
    }

    /**
     * Creates a link for a given package.
     * @param link The link options.
     */
    public link(link: ILinkOptions) {
        /*const app = App.instance();

        // If no package was given
        if (!link.package) {
            // If has no package.json
            if (!app.packageJson) {
                throw new Error("No package name was given and also a package.json wasn't found.");
            }
    
            // Create a new link for it
            const obj = app[link.global ? "globalConfig" : "localConfig"];

            // Create a link for it
            obj.links[app.packageJson.name] = process.cwd();

            // Save the configuration files
            app.save(link.global ? "global" : "local");
        }*/
    }

    /**
     * Creates multiple links for a given pattern.
     * @param link The link options.
     */
    public async mklink(link: {
        pattern: string;
        depth?: number;
    }) {
        // Remove the last slash from the pattern if has one
        if (link.pattern.endsWith("/")) {
            link.pattern = link.pattern.substring(0, link.pattern.length - 1);
        }

        const possibleProjectPaths = await glob.glob(link.pattern + "/", {
            maxDepth: link.depth,
            follow: true,
            absolute: true,
            cwd: process.cwd(),
            ignore: "node_modules/**"
        });

        for(const projectPath of possibleProjectPaths) {
            const packageJsonPath = path.resolve(projectPath, "package.json");

            // Ignore if there's no package.json in the folder
            if (!fs.existsSync(packageJsonPath)) {
                continue;
            }

            const packageJson = require(packageJsonPath);

            // Call a link for it
            await Yarn.execYarn({
                cmd: "link",
                cwd: projectPath
            });

            logger.info("linked package \"%s\"", packageJson.name);
        }
    }

    /**
     * Deletes a link for a given package.
     * @param unlink The link options.
     */
    public async unlink(unlink: ILinkOptions) {
        // If no package was given
        if (!unlink.package) {
            /*// If has no package.json
            if (!this.packageJson) {
                throw new Error("No package name was given and also a package.json wasn't found.");
            }
    
            // Create a new link for it
            const obj = this[unlink.global ? "globalConfig" : "localConfig"];

            // Create a link for it
            obj.links[this.packageJson.name] = process.cwd();

            // Save the configuration files
            this.save(unlink.global ? "global" : "local");*/

            return;
        }

        // If it's a global unlink
        if (unlink.global) {
            // Try finding the original link folder
            const linkFolder = await Yarn.getGlobalLinkSymlinkPath(unlink.package);

            // If no folder was found
            if (!linkFolder) {
                // Welp, there's nothing to do here
                return exitWithError("Unable to determine the location for \"%s\"", unlink.package);
            }

            logger.info("the folder for %s is %s", unlink.package, linkFolder);

            try {
                // If the symlink still exists
                if (fs.lstatSync(linkFolder).isSymbolicLink()) {
                    // If it's a broken symlink
                    if (!fs.existsSync(linkFolder)) {
                        // If it's not forcing a deletion
                        if (!unlink.force) {
                            return exitWithError("The given symlink doesn't resolve to anywhere. Use --force to abruptly delete the symlink.");
                        }

                        // Delete the symlink
                        await fs.promises.unlink(linkFolder);
                    } else {
                        // Just all unlink at the folder
                        await Yarn.execYarn({
                            cmd: "unlink",
                            cwd: path.resolve(linkFolder)
                        });
                    }
                } else {
                    throw new Error("Invalid symlink found.");
                }
            } catch(e) {
                console.error(e);

                return exitWithError("There's no symlink for \"%s\"", unlink.package);
            }
        }

        logger.info("the symlink for \"%s\" was sucessfully removed.", unlink.package);
    }

    /**
     * Perform all links based on configurations.
     */
    public performLinks() {
        /*if (this.config.rules) {
            for(const rule of this.config.rules) {
                if ("includes" in rule) {
                    this.processIncludeRule(rule.includes);
                }
            }
        }*/

        // If isn't ignoring global links
        if (!this.options.ignoreGlobalLinks) {
            this.processGlobalLinks();
        }

        logger.info("all packages were linked sucessfully");
    }

    /**
     * Processes a include rule.
     * @param include The name that needs to appear in the package names.
     */
    /*private async processIncludeRule(include: string) {
        // Iterate over all packages
        for(const packageName in this.getLocalPackages()) {
            // If the package name includes the given name
            if (packageName.includes(include)) {
                await this.performSingleLink(packageName);
            }
        }
    }*/

    /**
     * Processes all global links
     */
    private async processGlobalLinks() {
        for(const pkgName of await Yarn.getGloballyLinkedPackages()) {
            await App.instance().performSingleLink(pkgName);

            logger.info("sucessfully linked \"%s\"", pkgName);
        }
    }

    /**
     * Resets global links.
     * @param opts Any options to be passed to the resetter.
     */
    public async resetGlobalLinks(opts?: {
        /**
         * Will only delete broken symlinks.
         */
        onlyBroken?: boolean;
    }) {
        // Retrieve all linked packages
        for(const link of await Yarn.getGloballyLinkedPackages({
            includeBroken: opts?.onlyBroken
        })) {
            // Unlink it
            fs.unlinkSync(await Yarn.getGlobalLinkSymlinkPath(link));

            logger.info("unlinked \"%s\"", link);
        }
    }
}