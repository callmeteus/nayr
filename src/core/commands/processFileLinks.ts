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
        if (!Yarn.isLinked(pkgName)) {
            logger.info("\"%s\" isn't linked, will be linked first");

            // Link it
            await Yarn.link(pkgName);

            logger.info("successfully created a link for \"%s\"", pkgName);
        }

        await App.instance().performSingleLink(pkgName);

        logger.info("successfully linked file package \"%s\"", pkgName);
    }
}