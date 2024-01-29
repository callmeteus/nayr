import { CommandProcessor } from "../CommandProcessor";
import { logger } from "../Logger";
import { processFileLinks } from "./processFileLinks";
import { processGlobalLinks } from "./processGlobalLinks";

/**
 * Perform all links based on configurations.
 */
export const performLinks = async () => {
    /*if (CommandProcessor.instance.config.rules) {
        for(const rule of this.config.rules) {
            if ("includes" in rule) {
                this.processIncludeRule(rule.includes);
            }
        }
    }*/

    // If isn't ignoring global links
    if (!CommandProcessor.instance.options.ignoreGlobalLinks) {
        await processGlobalLinks();
    }

    // If isn't ignoring global links
    if (!CommandProcessor.instance.options.ignoreFileLinks) {
        await processFileLinks();
    }

    logger.info("all packages were linked sucessfully");
};