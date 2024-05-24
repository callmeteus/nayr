import { ChildProcess, spawn } from "child_process";
import * as cliProgress from "cli-progress";
import type { IYarnExecOptions } from "./Yarn";

import which from "which";

import * as fs from "fs";
import * as path from "path";
import { logger } from "../core/Logger";

interface IYarnAct<TType extends string, TData> {
    type: TType;
    data: TData;
}

type ISuccessAct = IYarnAct<"success", {
    data?: string;
}>;

type IStepAct = IYarnAct<"step", {
    message: string;
    current: number;
    total: number;
}>;

type IActivityTickAct = IYarnAct<"activityTick", {
    id: number;
    name: string;
}>;

type IProgressStartAct = IYarnAct<"progressStart", {
    id: number;
    total: number;
}>;

type IProgressTickAct = IYarnAct<"progressTick", {
    id: number;
    current: number;
}>;

type IProgressEndAct = IYarnAct<"progressFinish", {
    id: number;
}>;

type IInfoAct = IYarnAct<"info", string>;

type TActivityType = IStepAct | IActivityTickAct | IInfoAct | IProgressStartAct | IProgressTickAct | IProgressEndAct | ISuccessAct;

export class ExternalYarn {
    private static binPath: string;
    private static cliPath: string;
    private static resolvedExternalRegistryUrl: string;

    private static async getYarnBinPath() {
        if (!this.binPath) {
            try {
                // Try with 
                const possiblePaths = await which("yarn", {
                    all: true
                });

                this.binPath = possiblePaths.find((p) => !p.includes("\\Temp"));
            } catch(e) {
                // Ignore any errors
                throw new Error("yarn isn't installed or couldn't been found");
            }
        }

        return this.binPath;
    }

    /**
     * Retrieves the yarn CLI location and validates its existance.
     * @returns
     */
    public static async getYarnCliPath() {
        if (!this.cliPath) {
            const yarnBin = await this.getYarnBinPath();
            const yarnCli = path.resolve(
                yarnBin.replace(/yarn(\.(cmd|sh))?$/i, ""),
                "node_modules/yarn/lib/cli.js"
            );

            logger.debug("possible yarn CLI path is %s", yarnCli);

            if (!fs.existsSync(yarnCli)) {
                throw new Error("Unable to locate yarn lib folder.");
            }

            this.cliPath = yarnCli;
        }

        return this.cliPath;
    }

    public static getExternalRegistryURL() {
        if (this.resolvedExternalRegistryUrl === undefined) {
            const npmrcFilename = path.resolve(process.cwd(), ".npmrc");

            if (fs.existsSync(npmrcFilename)) {
                this.resolvedExternalRegistryUrl = fs.readFileSync(npmrcFilename, "utf-8").split("registry=").pop().split("\n")[0];
            } else {
                this.resolvedExternalRegistryUrl= null;
            }
        }

        return this.resolvedExternalRegistryUrl;
    }

    public childProcess: ChildProcess;

    public stdout: string = "";
    public stderr: string = "";

    public cliProgress: cliProgress.MultiBar;

    public cliBars: Record<string, cliProgress.Bar> = {};

    constructor(
        protected options: IYarnExecOptions
    ) {
        if (options.json && options.progress) {
            this.cliProgress = new cliProgress.MultiBar({
                emptyOnZero: true
            });
        }
    }

    /**
     * Builds the arguments for the exec command.
     * @returns 
     */
    private buildArguments() {
        const args = [
            this.options.cmd
        ];

        if (ExternalYarn.getExternalRegistryURL()) {
            args.push("--registry=" + ExternalYarn.getExternalRegistryURL());
        }
    
        if (this.options.args) {
            args.push(...typeof this.options.args === "string" ? [this.options.args] : this.options.args);
        }
    
        if (this.options.json) {
            args.push("--json");
        }
    
        if (this.options.progress === false) {
            args.push("--no-progress");
        }
    
        if (this.options.interactive === false) {
            args.push("--non-interactive");
        }

        return args;
    }
    
    private processProgress(progress: TActivityType) {
        switch(progress.type) {
            default:
                console.log("received unknown progress %O", progress);
            break;
            
            case "step": {
                this.cliBars.main = this.cliBars.main || this.cliProgress.create(
                    progress.data.total,
                    progress.data.current,
                    {
                        message: progress.data.message
                    },
                    {
                        format: "General progress |{bar}| {percentage}% || {value}/{total} {message}",
                    }
                );

                this.cliBars.main.update(progress.data.current);
            };
            break;

            case "activityTick":
                this.cliBars[progress.data.id].update(this.cliBars.main.getProgress(), {
                    message: progress.data.name
                });
            break;

            case "info":
                this.cliProgress.log(progress.data);
            break;

            case "progressStart":
                this.cliBars[progress.data.id] = this.cliProgress.create(progress.data.total, 0);
            break;

            case "progressFinish":
                this.cliProgress.remove(this.cliBars[progress.data.id]);
            break;

            case "progressTick":
                this.cliBars[progress.data.id].update(progress.data.current);
            break;
        }
    }

    public async run() {
        let bin = await ExternalYarn.getYarnBinPath();

        // If in win32, need to encapsulate the path string
        if (process.platform === "win32") {
            bin = `"${bin}"`;
        }

        this.childProcess = spawn(bin, this.buildArguments(), {
            cwd: this.options.cwd ?? process.cwd(),
            env: process.env,
            shell: true
        });

        await new Promise<void>((resolve, reject) => {
            const processLines = (data) => {
                if (this.options.json) {
                    const lines = data.toString("utf-8").split(/(\n)/);
    
                    for(const line of lines) {
                        if (!line.trim().length) {
                            continue;
                        }
    
                        const json = JSON.parse(line);
    
                        if (json.type === "error") {
                            reject(new Error(json.data));
                        } else
                        if (json.type === "success") {
                            // Ignore it
                        } else
                        if (json.type === "warning") {
                            // Ignore it
                        } else
                        if (this.options.progress) {
                            this.processProgress(json);
                        }
                    }
                }
            }

            this.childProcess.stdout.on("data", (data) => {
                processLines(data);

                this.stdout += data.toString("utf-8");
            });
        
            this.childProcess.stderr.on("data", (data) => {
                processLines(data);

                this.stderr += data.toString("utf-8");
            });

            this.childProcess.on("close", (code) => {
                // Clear the progress
                this.cliProgress && this.cliProgress.stop();

                if (code === 0) {
                    return resolve();
                }

                const err = new Error("Process exited with code " + code) as Error & Record<string, any>;
                err.stdout = this.stdout || null;
                err.stderr = this.stderr || null;
                
                reject(err);
            });

            this.childProcess.on("error", (err) => reject(err));
        });
    
        if (!this.options.progress && this.options.json) {
            return JSON.parse(this.stdout);
        }
    
        return this.stdout;
    }
}

/**
 * Executes yarn programatically.
 * @param options All options to be passed to the fork executor.
 * @returns 
 */
export const execYarn = async <
    TResult extends object | string,
    TOptions extends IYarnExecOptions = IYarnExecOptions 
>(options: TOptions): Promise<TResult> => {
    const yarn = new ExternalYarn(options);

    const result = await yarn.run();

    return result;
};