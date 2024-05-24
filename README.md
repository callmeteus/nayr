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