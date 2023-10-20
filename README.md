# nayr
Nayr allows you to automatically generate links for your yarn packages.

## Usage
You can install nayr globally and use it as a command line.

yarn
```
yarn global add nayr
```

npm
```
npm -G install nayr
```

Bunda is friends with the `postinstall` lifecycle hook.
You can hook it into your projects to automatically generate links for you:

```json
{
  "name": "my-important-project",
  "scripts": {
    "postinstall": "nayr"
  }
}
```
