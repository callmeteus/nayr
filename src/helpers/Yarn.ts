import axios from "axios";
import { execSync } from "child_process";

import * as fs from "fs";
import * as path from "path";

import { ExecutableYarn, execYarn as invokeYarn } from "./ExternalYarn";
import { logger } from "../core/Logger";

export interface IYarnExecOptions {
    cmd: string;
    args?: string | string[];
    json?: boolean;
    interactive?: boolean;
    progress?: boolean;
}

export class Yarn {
    /**
     * Executes a command synchronously and retrieves its stdout.
     * @param cmd The command to be executed.
     * @param json If needs to JSON.parse the output.
     * @returns 
     */
    private static execAndGetStdout(cmd: string, json: boolean = false) {
        const result = execSync(cmd, {
            env: process.env
        });

        if (!result) {
            return null;
        }

        const contents = result.toString("utf-8");

        if (json) {
            return JSON.parse(contents) as object;
        }

        return contents;
    }

    /**
     * The resolved node_modules directory.
     */
    public nodeModulesDir = path.resolve(process.cwd(), "node_modules");

    constructor() {
        
    }

    /**
     * Safely extracts the package name from patterns like `@package/name@1.0.0`.
     * @param pkgNameWithVersion The package name with the package version.
     * @returns 
     */
    private safeExtractPackageName(pkgNameWithVersion: string) {
        const lastIndex = pkgNameWithVersion.lastIndexOf("@");        
        return pkgNameWithVersion.slice(0, lastIndex);
    }

    /**
     * Retrieves the registry information about a given package.
     * @param pkgName The package name.
     * @returns
     */
    public async getPackageInfo(pkgName: string) {
        const url = new URL("/" + pkgName, ExecutableYarn.getExternalRegistryURL() ?? "https://replica.npmjs.com");
        const response = await axios.get(url.toString());

        return response.data;
    }

    /**
     * Retrieves the project dependencies.
     * @returns
     */
    public getDependencies() {
        return Yarn.execAndGetStdout("npm pkg get dependencies", true) as object;
    }

    /**
     * Retrieves the project dev dependencies.
     * @returns 
     */
    public getDevDependencies() {
        return Yarn.execAndGetStdout("npm pkg get devDependencies", true) as object;
    }

    /**
     * Retrieves all kinds of project dependencies.
     * @returns 
     */
    public getAllDependencies() {
        // Join the dev with the normal deps
        return {
            ...this.getDependencies(),
            ...this.getDevDependencies()
        };
    }

    /**
     * Determines the package name.
     * @param pkgName The package name.
     * @returns 
     */
    private getPkgPath(pkgName: string) {
        return path.resolve(process.cwd(), "node_modules", pkgName);
    }

    /**
     * Determines if a given package is installed.
     * @param pkgName The package name.
     * @returns
     */
    public isInstalled(pkgName: string) {
        const pkgPath = this.getPkgPath(pkgName);

        logger.silly("isInstalled %s @ %s", pkgName, pkgPath);

        return fs.existsSync(pkgPath);
    }

    /**
     * Determines if a given package is linked.
     * @param pkgName The package name.
     * @returns 
     */
    public isLinked(pkgName: string) {
        return this.isInstalled(pkgName) && fs.lstatSync(this.getPkgPath(pkgName)).isSymbolicLink()
    }

    /**
     * Retrieves the installed version of a given package.
     * @param pkgName The package name.
     * @returns
     */
    public async getPackageVersion(pkgName: string) {
        const why = await this.execYarn<{
            type: "tree";
            data: {
                type: "list",
                trees: {
                    name: string;
                    children: any[];
                    hint: string | null;
                    depth: number;
                }[];
            };
        }>({
            cmd: "list",
            args: ["--pattern", pkgName, "--depth=0"],
            json: true,
            interactive: false,
            progress: false
        });

        // Find the exact package with the name
        const packageData = why.data.trees.find((p) => this.safeExtractPackageName(p.name) === pkgName);

        // If no package was given, then it's probably not installed
        if (!packageData) {
            return null;
        }

        return packageData.name.split("@").pop();
    }

    /**
     * Retrieves the remote latest version of a given package.
     * @param pkgName The package name.
     * @returns 
     */
    public async determineLatestPackageVersion(pkgName: string) {
        return (await this.getPackageInfo(pkgName))["dist-tags"].latest;
    }

    /**
     * Installs a single package.
     * @param pkgName The package name.
     * @returns
     */
    public install(pkgName?: string) {
        return this.execYarn({
            cmd: "add",
            args: [pkgName],
            interactive: false,
            progress: true,
            json: true
        });
    }

    /**
     * Links a single package.
     * @param pkgName The package name.
     * @returns
     */
    public link(pkgName: string) {
        return this.execYarn({
            cmd: "link",
            args: [pkgName],
            interactive: false,
            progress: true,
            json: true
        });
    }

    /**
     * Upgrades a single package.
     * @param pkgName The package name.
     * @returns
     */
    public upgrade(pkgName?: string) {
        return this.execYarn({
            cmd: "upgrade",
            args: [pkgName],
            interactive: false,
            progress: true,
            json: true
        });
    }

    /**
     * Retrieves the yarn links folder location.
     * @returns 
     */
    public async getLinksPath() {
        const binFolder = await this.execYarn<string>({
            cmd: "global",
            args: ["bin"],
            json: false,
            progress: false,
            interactive: false
        });

        return path.resolve(binFolder.replace("bin", "Data/link")).trim();
    }

    /**
     * Retrieves all globally linked packages
     */
    public async getGloballyLinkedPackages() {
        const linksPath = await this.getLinksPath();

        const rootItems = await fs.promises.readdir(linksPath, {
            recursive: false
        });

        const items: string[] = [...rootItems];

        for(const item of rootItems) {
            // If starts with a "@"
            if (item.startsWith("@")) {
                // Also load its children
                const children = await fs.promises.readdir(
                    path.resolve(linksPath, item)
                );

                items.push(...children.map((c) => item + "/" + c));

                // Remove it from the root
                items.splice(items.indexOf(item), 1);
            }
        }

        // Iterate over all items
        for(const item of items) {
            // Ignore if it isn't a folder
            if (!(await fs.promises.stat(path.resolve(linksPath, item))).isDirectory()) {
                items.splice(items.indexOf(item), 1);
            }
        }

        return items;
    }

    /**
     * Executes yarn programatically.
     * @param options All options to be passed to the fork executor.
     * @returns 
     */
    private async execYarn<
        TResult,
        TOptions extends IYarnExecOptions = IYarnExecOptions
    >(options: TOptions): Promise<TResult> {
        return invokeYarn(options) as TResult;
    }
}