import { Yarn } from "../../helpers/Yarn";
import { App, ILinkOptions } from "../App";

/**
 * Creates a link for a given package.
 * @param link The link options.
 */
export const link = async (link: ILinkOptions) => {
    const app = App.instance();

    // If no package was given
    if (!link.package) {
        // If has no package.json
        /*if (!app.packageJson) {
            throw new Error("No package name was given and also a package.json wasn't found.");
        }

        // Create a new link for it
        const obj = app[link.global ? "globalConfig" : "localConfig"];

        // Create a link for it
        obj.links ??= {};
        obj.links[app.packageJson.name] = process.cwd();

        console.log(app);

        // Save the configuration files
        //app.save(link.global ? "global" : "local");*/

        // Link the current package
        await Yarn.link();
    }
}