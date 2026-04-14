import path from "path";
import { Yarn } from "../../helpers/Yarn";
import { App } from "../App";
import { logger } from "../Logger";

/**
 * Processes all file package links
 */
export const processFileLinks = async () => {
    const app = App.instance();
    const pkgs = app.getLocalPackages();

    for (const pkgName in pkgs) {
        const pkgPathOrVersion = pkgs[pkgName];

        // If it's a file link
        if (pkgPathOrVersion.startsWith("file:")) {
            // If it's not linked yet, link it
            if (!await Yarn.packageHasLink(pkgName)) {
                logger.info("local package \"%s\" isn't linked, will create a link for it first", pkgName);

                const packagePath = pkgPathOrVersion.replace(/file\:(\/\/)?/, "");

                // Create a link for it
                await Yarn.link(null, {
                    cwd: path.resolve(process.cwd(), packagePath)
                });

                logger.info("successfully created a link for \"%s\"", pkgName);
            }

            await App.instance().performSingleLink(pkgName);

            logger.info("successfully linked local package \"%s\"", pkgName);
        } else
        // If it's a workspace dependency (e.g. workspace:*, workspace:^, workspace:~)
        if (pkgPathOrVersion.startsWith("workspace:")) {
            // If it's not linked yet, create the global link first
            if (!await Yarn.packageHasLink(pkgName)) {
                logger.info("workspace package \"%s\" isn't linked, will create a link for it first", pkgName);

                const workspacePath = await Yarn.resolveWorkspacePackagePath(pkgName);

                // If the workspace package wasn't found in any workspace pattern
                if (!workspacePath) {
                    logger.warn("workspace package \"%s\" was not found in any workspace", pkgName);
                    continue;
                }

                // Create a global link from the workspace package folder
                await Yarn.link(null, { cwd: workspacePath });

                logger.info("successfully created a link for \"%s\"", pkgName);
            }

            await App.instance().performSingleLink(pkgName);

            logger.info("successfully linked workspace package \"%s\"", pkgName);
        }
    }
}