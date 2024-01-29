import { App } from "./App";

import colors from "colors";
import deepmerge from "deepmerge";

import { logger } from "./Logger";
import { YarnDetourer } from "./YarnDetourer";

import * as Commands from "./Command";

interface IOptions {
    ignoreGlobalLinks?: boolean;
    ignoreFileLinks?: boolean;
    verbose?: boolean;
    headless?: boolean;
}

export class CommandProcessor {
    public static instance: CommandProcessor;

    constructor(
        public options: IOptions = {}
    ) {
        this.setOptions(options);

        CommandProcessor.instance = this;
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
                return Commands.performLinks();

            /**
             * Link-related commands
             */

            case "link":
                return Commands.link(args as any);
    
            case "mklink":
                return Commands.mklink(args as any);
    
            case "unlink":
                return Commands.unlink(args as any);
    
            case "reset-global-links":
                return Commands.resetGlobalLinks(args as any);

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
}