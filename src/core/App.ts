import * as path from "path";
import * as os from "os";
import * as fs from "fs";

import yaml from "yaml";
import deepmerge from "deepmerge";
import { Yarn } from "../helpers/Yarn";
import { logger } from "./Logger";

interface ILinkOptions {
    package?: string;
    global?: boolean;
}

interface IConfig {
    links?: Record<string, string | boolean>;
    
    includeGlobalLinks?: boolean;

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
    };

    private yarn = new Yarn();

    constructor() {
        this.setup();
    }

    /**
     * Sets new app configurations.
     * @param config The new configuration to be set.
     */
    public setConfig(config?: Partial<IConfig>) {
        this.config = deepmerge(this.config, config);
    }

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
     * Retrieves the global configuration filename.
     * @returns 
     */
    public getGlobalConfigFilename() {
        return path.resolve(os.homedir(), ".autolinker", "config.yml");
    }

    /**
     * Retrieves the global link cache filename.
     * @returns 
     */
    public getGlobalLinkCacheFilename() {
        return path.resolve(os.homedir(), ".autolinker", "cache.yml");
    }

    /**
     * Retrieves the local configuration filename.
     * @returns 
     */
    public getLocalConfigFilename() {
        return path.resolve(process.cwd(), ".autolinker");
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

        if (this.config.includeGlobalLinks) {
            this.processGlobalLinks();
        }

        logger.info("all packages were linked sucessfully");
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
            ...this.packageJson.peerDependencies ?? {}
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
                logger.info("failed to link \"%s\": %O", packageName, e);

                process.exit(1);
            }
        }

        logger.info("sucessfully linked \"%s\"", packageName);
    }
}