import { Yarn } from "../../helpers/Yarn";
import { App } from "../App";
import { logger } from "../Logger";

/**
 * Processes all global links
 */
export const processGlobalLinks = async () => {
    const app = App.instance();
    const pkgs = app.getLocalPackages();

    for (const pkgName of await Yarn.getGloballyLinkedPackages()) {
        // Ignore if this package isn't required
        if (!(pkgName in pkgs)) {
            continue;
        }

        await App.instance().performSingleLink(pkgName);

        logger.info("successfully linked \"%s\"", pkgName);
    }
}