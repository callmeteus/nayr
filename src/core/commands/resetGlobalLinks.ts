import { unlinkSync } from "fs";
import { Yarn } from "../../helpers/Yarn";
import { logger } from "../Logger";

/**
     * Resets global links.
     * @param opts Any options to be passed to the resetter.
     */
export const resetGlobalLinks = async (opts?: {
    /**
     * Will only delete broken symlinks.
     */
    onlyBroken?: boolean;
}) => {
    // Retrieve all linked packages
    for (const link of await Yarn.getGloballyLinkedPackages({
        includeBroken: opts?.onlyBroken
    })) {
        // Unlink it
        unlinkSync(await Yarn.getGlobalLinkSymlinkPath(link));

        logger.info("unlinked \"%s\"", link);
    }
}