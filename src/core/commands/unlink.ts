import path from "path";
import { exitWithError } from "../../helpers/Process";
import { Yarn } from "../../helpers/Yarn";
import { ILinkOptions } from "../App";
import { logger } from "../Logger";

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

    // If package is ".", we need to unlink the current package
    if (unlink.package === ".") {
        const packageJsonPath = path.resolve(process.cwd(), "package.json");

        // If no package.json was found
        if (!fs.existsSync(packageJsonPath)) {
            return exitWithError("No package.json found in the current directory.");
        }

        // Read the package.json file
        const packageJson = JSON.parse(
            fs.readFileSync(
                packageJsonPath,
                "utf8"
            )
        );

        // Set the package name
        unlink.package = packageJson.name;
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
                const realPath = fs.realpathSync(linkFolder);

                // If it's a broken symlink
                if (!fs.existsSync(realPath)) {
                    // If it's not forcing a deletion
                    if (!unlink.force) {
                        return exitWithError("The given symlink doesn't resolve to anywhere. Use --force to abruptly delete the symlink.");
                    }

                    logger.info("broken symlink found, deleting");

                    // Delete the symlink
                    await fs.promises.unlink(linkFolder);
                } else {
                    try {
                        // Just all unlink at the folder
                        await Yarn.execYarn({
                            cmd: "unlink",
                            cwd: realPath
                        });
                    } catch(e) {
                        return exitWithError("Error unlinking %s (%s): %O", linkFolder, realPath, e);
                    }
                }
            } else {
                return exitWithError("Invalid symlink found.");
            }
        } catch(e) {
            console.error(e);

            return exitWithError("There's no symlink for \"%s\"", unlink.package);
        }
    }

    logger.info("the symlink for \"%s\" was sucessfully removed.", unlink.package);
}