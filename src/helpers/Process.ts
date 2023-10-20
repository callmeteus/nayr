import { logger } from "../core/Logger";

export function exitWithError(message: string, ...params: any[]) {
    logger.error(message, ...params);
    process.exit(1);
}