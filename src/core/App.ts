import * as path from "path";
import * as os from "os";
import * as fs from "fs";

import yaml from "yaml";
import deepmerge from "deepmerge";
import { Yarn } from "../helpers/Yarn";
import { logger } from "./Logger";

import colors from "colors";
import * as glob from "glob";

const appPackageJson = require("../../package.json");

interface ILinkOptions {
    package?: string;
    global?: boolean;
    force?: boolean;
}

interface IConfig {
    links?: Record<string, string | boolean>;
    
    ignoreGlobalLinks?: boolean;

    rules?: ({
        includes: string;
    } | {
        matches: string;  
    })[];
}

export class App {
    private globalConfig: IConfig = {};
    private localConfig: IConfig = {};
    private config: IConfig = {};

    private packageJson: {
        name?: string;
        dependencies?: Record<string, string>;
        devDependencies?: Record<string, string>;
        localDependencies?: Record<string, string>;
        peerDependencies?: Record<string, string>;
        optionalDependencies?: Record<string, string>;
    };

    private yarn = new Yarn();
    private version: string;

    constructor() {
        this.setup();

        this.version = appPackageJson.version;

        console.log(colors.bold("nayr v%s"), this.version);
    }

    /**
     * Exits the application and displays an error.
     * @param message The error message.
     * @param params Any params to be passed to the console.error message.
     */
    public exitWithError(message: string, ...params: any[]) {
        logger.error(message, ...params);
        process.exit(1);
    }

    /**
     * Sets new app configurations.
     * @param config The new configuration to be set.
     */
    public setConfig(config?: Partial<IConfig>) {
        this.config = deepmerge(this.config, config);
    }

    /**
     * Retrieves the global configuration filename.
     * @returns 
     */
    public getGlobalConfigFilename() {
        return path.resolve(os.homedir(), ".nayr", "config.yml");
    }

    /**
     * Retrieves the global link cache filename.
     * @returns 
     */
    public getGlobalLinkCacheFilename() {
        return path.resolve(os.homedir(), ".nayr", "cache.yml");
    }

    /**
     * Retrieves the local configuration filename.
     * @returns 
     */
    public getLocalConfigFilename() {
        return path.resolve(process.cwd(), ".nayr");
    }

    /**
     * Creates a link for a given package.
     * @param link The link options.
     */
    public link(link: ILinkOptions) {
        // If no package was given
        if (!link.package) {
            // If has no package.json
            if (!this.packageJson) {
                throw new Error("No package name was given and also a package.json wasn't found.");
            }
    
            // Create a new link for it
            const obj = this[link.global ? "globalConfig" : "localConfig"];

            // Create a link for it
            obj.links[this.packageJson.name] = process.cwd();

            // Save the configuration files
            this.save(link.global ? "global" : "local");
        }
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

        const possibleProjects = await glob.glob(link.pattern + "/", {
            maxDepth: link.depth,
            follow: true,
            absolute: true,
            cwd: process.cwd(),
            ignore: "node_modules/**"
        });

        for(const projectPath of possibleProjects) {
            const packageJsonPath = path.resolve(projectPath, "package.json");

            // Ignore if there's no package.json in the folder
            if (!fs.existsSync(packageJsonPath)) {
                continue;
            }

            const packageJson = require(packageJsonPath);

            // Call a link for it
            await this.yarn.execYarn({
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
            // If has no package.json
            if (!this.packageJson) {
                throw new Error("No package name was given and also a package.json wasn't found.");
            }
    
            // Create a new link for it
            const obj = this[unlink.global ? "globalConfig" : "localConfig"];

            // Create a link for it
            obj.links[this.packageJson.name] = process.cwd();

            // Save the configuration files
            this.save(unlink.global ? "global" : "local");

            return;
        }

        // If it's a global unlink
        if (unlink.global) {
            // Try finding the original link folder
            const linkFolder = await this.yarn.getGlobalLinkSymlinkPath(unlink.package);

            // If no folder was found
            if (!linkFolder) {
                // Welp, there's nothing to do here
                return this.exitWithError("Unable to determine the location for \"%s\"", unlink.package);
            }

            logger.info("the folder for %s is %s", unlink.package, linkFolder);

            try {
                // If the symlink still exists
                if (fs.lstatSync(linkFolder).isSymbolicLink()) {
                    // If it's a broken symlink
                    if (!fs.existsSync(linkFolder)) {
                        // If it's not forcing a deletion
                        if (!unlink.force) {
                            return this.exitWithError("The given symlink doesn't resolve to anywhere. Use --force to abruptly delete the symlink.");
                        }

                        // Delete the symlink
                        await fs.promises.unlink(linkFolder);
                    } else {
                        // Just all unlink at the folder
                        await this.yarn.execYarn({
                            cmd: "unlink",
                            cwd: path.resolve(linkFolder)
                        });
                    }
                } else {
                    throw new Error("Invalid symlink found.");
                }
            } catch(e) {
                console.error(e);

                return this.exitWithError("There's no symlink for \"%s\"", unlink.package);
            }
        }

        logger.info("the symlink for \"%s\" was sucessfully removed.", unlink.package);
    }

    /**
     * Saves a given target.
     * @param target The saving target.
     */
    public save(target?: "global" | "local") {
        if (target === "global") {
            const contents = yaml.stringify(this.globalConfig);
            fs.writeFileSync(this.getGlobalConfigFilename(), contents);
        } else {
            const contents = yaml.stringify(this.localConfig);
            fs.writeFileSync(this.getLocalConfigFilename(), contents);
        }
    }

    /**
     * Perform all links based on configurations.
     */
    public performLinks() {
        if (this.config.rules) {
            for(const rule of this.config.rules) {
                if ("includes" in rule) {
                    this.processIncludeRule(rule.includes);
                }
            }
        }

        // If isn't ignoring global links
        if (!this.config.ignoreGlobalLinks) {
            this.processGlobalLinks();
        }

        logger.info("all packages were linked sucessfully");
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
        for(const link of await this.yarn.getGloballyLinkedPackages({
            includeBroken: opts?.onlyBroken
        })) {
            // Unlink it
            fs.unlinkSync(await this.yarn.getGlobalLinkSymlinkPath(link));

            logger.info("unlinked \"%s\"", link);
        }
    }

    /**
     * Sets up the application.
     */
    private setup() {
        if (fs.existsSync(this.getGlobalConfigFilename())) {
            this.globalConfig = yaml.parse(
                fs.readFileSync(this.getGlobalConfigFilename(), "utf-8")
            );
        }

        if (fs.existsSync(this.getLocalConfigFilename())) {
            this.localConfig = yaml.parse(
                fs.readFileSync(this.getLocalConfigFilename(), "utf-8")
            );
        }

        this.config = deepmerge(this.globalConfig, this.localConfig);

        // Try finding a package.json at the root directory
        const packageJsonFile = path.resolve(process.cwd(), "package.json");

        // If no package.json exists
        if (fs.existsSync(packageJsonFile)) {
            this.packageJson = require(packageJsonFile);
        }
    }

    /**
     * Retrieves all local installed packages.
     * @returns 
     */
    private getLocalPackages() {
        return {
            ...this.packageJson.dependencies ?? {},
            ...this.packageJson.devDependencies ?? {},
            ...this.packageJson.localDependencies ?? {},
            ...this.packageJson.peerDependencies ?? {},
            ...this.packageJson.optionalDependencies ?? {}
        };
    }

    /**
     * Processes a include rule.
     * @param include The name that needs to appear in the package names.
     */
    private async processIncludeRule(include: string) {
        // Iterate over all packages
        for(const packageName in this.getLocalPackages()) {
            // If the package name includes the given name
            if (packageName.includes(include)) {
                await this.performSingleLink(packageName);
            }
        }
    }

    /**
     * Processes all global links
     */
    private async processGlobalLinks() {
        for(const link of await this.yarn.getGloballyLinkedPackages()) {
            await this.performSingleLink(link);
        }
    }

    /**
     * Performs a single package link.
     * @param packageName The package name to be linked.
     * @returns 
     */
    private async performSingleLink(packageName: string) {
        // Ignore if it's not installed
        if (!this.yarn.isInstalled(packageName)) {
            logger.silly("%s isn't installed, will ignore it", packageName);
            return;
        }

        // Ignore if it's already linked
        if (this.yarn.isLinked(packageName)) {
            logger.silly("%s is already linked, will ignore it", packageName);
            return;
        }

        logger.info("will link %s via include rule", packageName);

        try {
            // Try performing a link for it
            await this.yarn.link(packageName);
        } catch(e) {
            if (e.message.includes("No registered package")) {
                logger.warn("no registered package \"%s\" was found", packageName);
            } else {
                return this.exitWithError("failed to link \"%s\": %O", packageName, e);
            }
        }

        logger.info("sucessfully linked \"%s\"", packageName);
    }
}