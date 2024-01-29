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

        // If it's not a file link, ignore it
        if (!pkgPathOrVersion.startsWith("file:")) {
            continue;
        }

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
    }
}