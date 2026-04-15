# Nayr
Nayr allows you to automatically generate links for your Yarn packages, making package management easier and more efficient.
Nayr is an NPM package designed to simplify the process of linking packages that were previously linked using yarn link. It automatically links all registered packages, saving you time and effort.

## Installation
You can install Nayr globally and use it via the command line.

### Using Yarn
```sh
yarn global add nayr
```

### Using npm
```sh
npm install -g nayr
```

## Development - Linking locally for testing

When iterating on nayr itself, you can link the binary directly into the active node's bin directory so `nayr` resolves from anywhere without PATH changes.

> Requires nvm to be active (`source ~/.nvm/nvm.sh`) before running.
> Run `yarn build` first if you haven't already.

```sh
# Link nayr to the active nvm node bin (idempotent - safe to re-run)
source ~/.nvm/nvm.sh && yarn link:dev

# Verify
which nayr        # ~/.nvm/versions/node/vXX/bin/nayr
nayr --help

# Remove the link when done
source ~/.nvm/nvm.sh && yarn unlink:dev
```

The link points to `bin/nayr.js` in the source tree, so changes take effect after `yarn build` without re-linking.

## Usage
Nayr integrates seamlessly with the postinstall lifecycle hook. You can add it to your project's package.json to automatically generate links after dependencies are installed.

Add the following to your package.json:
```json
{
  "name": "my-important-project",
  "scripts": {
    "postinstall": "nayr"
  }
}
```

Alternatively, you can simply run nayr in your project directory to generate links manually.

```sh
nayr
```