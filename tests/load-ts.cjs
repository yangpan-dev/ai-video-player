// Load main-process TypeScript with only Electron's application paths substituted.
// Codec decisions, FFmpeg processes, filesystem/cache and HTTP streaming stay real.
const { readFileSync, existsSync } = require('node:fs')
const { resolve, dirname } = require('node:path')
const { createRequire } = require('node:module')
const ts = require('typescript')
module.exports = function createLoader(electron) {
  const cache = new Map()
  function load(filename) {
    filename = resolve(filename)
    if (cache.has(filename)) return cache.get(filename).exports
    const module = { exports: {} }
    cache.set(filename, module)
    const nativeRequire = createRequire(filename)
    const localRequire = (name) => {
      if (name === 'electron') return electron
      if (name.startsWith('@shared/')) return load(resolve('src/shared', name.slice(8) + '.ts'))
      if (name.startsWith('.')) {
        const path = resolve(dirname(filename), name)
        if (existsSync(path + '.ts')) return load(path + '.ts')
      }
      return nativeRequire(name)
    }
    const { outputText } = ts.transpileModule(readFileSync(filename, 'utf8'), {
      compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS, esModuleInterop: true }
    })
    new Function('require', 'module', 'exports', '__dirname', outputText)(localRequire, module, module.exports, dirname(filename))
    return module.exports
  }
  return load
}
