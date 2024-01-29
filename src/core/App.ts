import * as path from "path";
import * as os from "os";
import * as fs from "fs";

import yaml from "yaml";
import deepmerge from "deepmerge";

import { Yarn } from "../helpers/Yarn";
import { logger } from "./Logger";

import { exitWithError } from "../helpers/Process";

const appPackageJson = require("../../package.json");

export interface ILinkOptions {
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
    private static _instance: App;

    public static instance() {
        if (!this._instance) {
            this._instance = new App();
        }

        return this._instance;
    }

    private globalConfig: IConfig = {};
    private localConfig: IConfig = {};
    private config: IConfig = {};

    /**
     * The package.json contents for the current project.
     */
    public packageJson: {
        name?: string;
        dependencies?: Record<string, string>;
        devDependencies?: Record<string, string>;
        localDependencies?: Record<string, string>;
        peerDependencies?: Record<string, string>;
        optionalDependencies?: Record<string, string>;
    };

    /**
     * The current application version.
     */
    public version: string;

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
     * Sets up the application.
     */
    private setup() {
        this.version = appPackageJson.version;

        // If there's a global file
        if (fs.existsSync(this.getGlobalConfigFilename())) {
            // Load it
            this.globalConfig = yaml.parse(
                fs.readFileSync(this.getGlobalConfigFilename(), "utf-8")
            );
        }

        // If there's a local file
        if (fs.existsSync(this.getLocalConfigFilename())) {
            // Load it
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
    public getLocalPackages() {
        return {
            ...this.packageJson.dependencies ?? {},
            ...this.packageJson.devDependencies ?? {},
            ...this.packageJson.localDependencies ?? {},
            ...this.packageJson.peerDependencies ?? {},
            ...this.packageJson.optionalDependencies ?? {}
        };
    }

    /**
     * Performs a single package link.
     * @param packageName The package name to be linked.
     * @returns 
     */
    public async performSingleLink(packageName: string) {
        // Ignore if it's not installed
        if (!Yarn.isInstalled(packageName)) {
            logger.silly("%s isn't installed, will ignore it", packageName);
            return;
        }

        // Ignore if it's already linked
        if (Yarn.isLinked(packageName)) {
            logger.silly("%s is already linked, will ignore it", packageName);
            return;
        }

        logger.debug("will try to link %s...", packageName);

        try {
            // Try performing a link for it
            await Yarn.link(packageName);
        } catch(e) {
            if (e.message.includes("No registered package")) {
                logger.warn("no registered package \"%s\" was found", packageName);
            } else {
                return exitWithError("failed to link \"%s\": %O", packageName, e);
            }
        }

        logger.debug("sucessfully linked \"%s\"", packageName);
    }
}