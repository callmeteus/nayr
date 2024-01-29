import { exitWithError } from "../../helpers/Process";
import { Yarn } from "../../helpers/Yarn";
import { ILinkOptions } from "../App";
import { logger } from "../Logger";

import * as path from "path";
import * as fs from "fs";

/**
 * Deletes a link for a given package.
 * @param unlink The link options.
 */
export const unlink = async (unlink: ILinkOptions) => {
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