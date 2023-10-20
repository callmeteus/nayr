import { App } from "./App";

import * as fs from "fs";
import { logger } from "./Logger";
import { ExternalYarn } from "../helpers/ExternalYarn";
import { exitWithError } from "../helpers/Process";

export class YarnDetourer {
    /**
     * Detour the `yarn add` function.
     */
    public detourAdd() {
        return this.makeDetour(async (cliContents) => {
            // Check if it's already installed
            if (this.isDetoured(cliContents, "add")) {
                // Remove it
                logger.info("yarn seems to be detoured already, will remove the existing detour");

                cliContents = this.removeDetour(cliContents, "add");
            }

            // Patch it
            const patchedYarn = cliContents.replace(
                "var currentStep = 0;",
                this.generateInstallSnippet() + "\nvar currentStep = 0;"
            );

            logger.info("`yarn add` was sucessfully patched");

            return patchedYarn;
        });
    }

    /**
     * Removes the detour from the `yarn add` function.
     */
    public detourRemove() {
        return this.makeDetour(async (cliContents) => {
            // Check if it's already installed
            if (!this.isDetoured(cliContents, "add")) {
                // Remove it
                logger.warn("yarn seems to not be detoured");

                return cliContents;
            }

            cliContents = this.removeDetour(cliContents, "add");

            logger.info("`yarn add` was sucessfully de-patched");

            return cliContents;
        });
    }

    private async loadCliBody() {
        return fs.readFileSync(await ExternalYarn.getYarnCliPath(), "utf-8");
    }

    private async writeCliBody(body: string) {
        // Write it back to the yarn location
        return fs.writeFileSync(await ExternalYarn.getYarnCliPath(), body);
    }

    /**
     * Creates a backup for the CLI file.
     * @returns 
     */
    private async backupCli() {
        const cliPath = await ExternalYarn.getYarnCliPath();
        const bkpPath = cliPath + "-" + (+new Date()) + ".bk";

        fs.writeFileSync(
            bkpPath,
            fs.readFileSync(cliPath, "utf-8")
        );

        return bkpPath;
    }

    /**
     * Generates a signed snippet.
     * @param operation The snippet operation name.
     * @param body The snippet body.
     * @returns 
     */
    private generateSnippet(operation: string, body: string) {
        return [
            this.generateSnippetHeader(operation),
            body,
            this.generateSnippetFooter(operation)
        ].join("\n").trim();
    }

    private generateSnippetHeader(op: string, includeVersion: boolean = true) {
        return "// NAYR_DETOUR_START " + op + (includeVersion ? (" " + App.instance().version) : "");
    }

    private generateSnippetFooter(op: string) {
        return "// NAYR_DETOUR_END " + op;
    }

    /**
     * Generates the install detour snippet.
     * @returns 
     */
    private generateInstallSnippet() {
        return this.generateSnippet("add", /*txt*/`
            steps.push(function (curr, total) {
                _this2.reporter.step(curr, total, "nayr: linking modules", emoji.get("recycle"));

                return new Promise(function(resolve, reject) {
                    try {
                        var child = require("child_process");

                        var p = child.exec("nayr --headless");

                        p.stderr.on("data", function(d) {
                            _this2.reporter.warn(d.toString("utf-8"))
                        });

                        p.on("close", function() {
                            resolve();
                        });
                    } catch(e) {
                        console.error("failed running nayr: %O", e);
                        reject(e);
                    }
                });
            });
        `);
    }

    /**
     * Performs a detour by using a callback.
     * @param cb The detour callback.
     * @returns 
     */
    private async makeDetour(cb: (cliBody: string) => string | Promise<string>) {
        try {
            await this.backupCli();

            let body = await this.loadCliBody();

            try {
                body = await cb(body);

                return await this.writeCliBody(body);
            } catch(e) {
                return exitWithError(e);
            }
        } catch(e) {
            // If there was a permission issue
            if (e.code === "EPERM") {
                return exitWithError("unsufficient permissions to patch the yarn CLI file. Make sure that you are running as a superuser.");
            }

            throw e;
        }
    }

    /**
     * Determines if a given CLI body is already detoured for a given operation.
     * @param cliBody The CLI body.
     * @param op The operation name.
     * @returns 
     */
    private isDetoured(cliBody: string, op: string) {
        return (
            cliBody.includes(this.generateSnippetHeader(op)) &&
            cliBody.includes(this.generateSnippetFooter(op))
        );
    }

    /**
     * Removes an existing detour from a given CLI body.
     * @param cliBody The CLI body.
     * @param op The operation name.
     */
    private removeDetour(cliBody: string, op: string) {
        const header = this.generateSnippetHeader(op, false);
        const footer = this.generateSnippetFooter(op);

        return (
            cliBody.substring(0, cliBody.indexOf(header)) +
            cliBody.substring(cliBody.indexOf(footer) + footer.length)
        );
    }
}