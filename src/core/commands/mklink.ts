import * as fs from "fs";
import { glob } from "glob";
import * as path from "path";
import { Yarn } from "../../helpers/Yarn";
import { logger } from "../Logger";

/**
 * Creates multiple links for a given pattern.
 * @param link The link options.
 */
export const mklink = async(link: {
    pattern: string;
    depth?: number;
}) => {
    // If there's no pattern
    if (!link.pattern) {
        return logger.error("no pattern was given");
    }

    // Remove the last slash from the pattern if has one
    if (link.pattern.endsWith("/")) {
        link.pattern = link.pattern.substring(0, link.pattern.length - 1);
    }

    const possibleProjectPaths = await glob.glob(link.pattern + "/", {
        maxDepth: link.depth,
        follow: true,
        absolute: true,
        cwd: process.cwd(),
        ignore: "node_modules/**"
    });

    // If there's no possible project paths
    if (!possibleProjectPaths.length) {
        logger.error("found no folders matching the pattern \"%s\"", link.pattern);
        return;
    }

    for (const projectPath of possibleProjectPaths) {
        const packageJsonPath = path.resolve(projectPath, "package.json");

        // Ignore if there's no package.json in the folder
        if (!fs.existsSync(packageJsonPath)) {
            continue;
        }

        const packageJson = require(packageJsonPath);

        // Call a link for it
        await Yarn.execYarn({
            cmd: "link",
            cwd: projectPath
        });

        logger.info("linked package \"%s\"", packageJson.name);
    }
};