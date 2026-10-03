# vendor/kugou —— 第三方代码（KuGouMusicApi）

**来源**

| 项 | 值 |
| --- | --- |
| 仓库 | https://github.com/MakcRe/KuGouMusicApi |
| 版本 | `1.6.2`（见上游 `package.json`） |
| 分支 / commit | `main` / `da5ccfd9304c043085a2fd18e94ebc5c315044ab`（2026-10-01） |
| 下载地址 | https://codeload.github.com/MakcRe/KuGouMusicApi/tar.gz/refs/heads/main |
| 许可 | MIT，Copyright (c) 2023 MakcRe —— 全文见同目录 [`LICENSE`](./LICENSE) |
| 本目录内容 | 上游 `module/`（全部 237 个接口文件）+ `util/`（全部 10 个文件）+ `LICENSE`，**逐字节原样拷贝，未做任何修改** |

**用途与分发范围**

- 本目录为**第三方代码**，仅在**构建期**被 `src/kugou_source.js` 通过 `createRequire()` 以 CJS 方式加载，
  再由 esbuild 打进 `dist/main.js`。
- **不随 App 分发源码**：`pubspec.yaml` 只把 `assets/nodejs-project/dist/` 与若干白名单文件作为资产打包，
  `vendor/` 不在其中（也刻意**没有**放进 `src/`，因为 `pubspec.yaml` 会把整个 `src/` 当资产打进 App）。
- 设备上只会看到 `dist/main.js` 这个 bundle，看不到本目录。

**为什么需要同目录的 `package.json`**

本工程的 `assets/nodejs-project/package.json` 是 `"type": "module"`，而上游代码是 **CommonJS**。
最近的 `package.json` 决定 `.js` 文件的模块类型，因此在 `vendor/kugou/` 放一个
`{"type":"commonjs"}` 才能让这些 `.js` 被 `require()` 正常加载（否则会抛
`require is not defined in ES module scope`）。

**缺失依赖**

上游 `util/` 需要 `pako`、`big-integer`、`node-forge`，`module/` 需要 `axios`、`crypto-js`、
`form-data`、`qrcode`。这些都装在 `assets/nodejs-project/package.json` 的 `dependencies` 里
（版本见该文件），`npm run build` 时由 esbuild 打进 bundle —— 设备上不发 `node_modules`。

**MIT 合规**

上游要求保留版权与许可声明。除了本目录的 `LICENSE` 原文件，桥接层
`src/kugou_source.js` 的文件头也写明了出处与许可。
