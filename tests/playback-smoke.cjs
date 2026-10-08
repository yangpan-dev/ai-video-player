// Run after building: MEDIA_TEST_MANIFEST=/tmp/... node --test tests/media.test.cjs
// then MEDIA_TEST_MANIFEST=/tmp/... electron tests/playback-smoke.cjs
const electron = require('electron')
const { app, BrowserWindow, protocol } = electron
const { readFileSync, mkdtempSync } = require('node:fs')
const { join, resolve } = require('node:path')
const assert = require('node:assert/strict')
const manifest = JSON.parse(readFileSync(process.env.MEDIA_TEST_MANIFEST, 'utf8'))
const profile = mkdtempSync(join(manifest.dir, 'electron-profile-'))
app.setPath('userData', profile)
app.commandLine.appendSwitch('autoplay-policy', 'no-user-gesture-required')
protocol.registerSchemesAsPrivileged([{ scheme: 'media', privileges: { standard: true, secure: true, supportFetchAPI: true, stream: true } }])
const load = require('./load-ts.cjs')({ ...electron, app: {
  isPackaged: false, getAppPath: () => profile, getPath: (name) => app.getPath(name)
} })
const { mediaHandler } = load('src/main/services/mediaProtocol.ts')
const cache = load('src/main/services/playbackCache.ts')
const { registerIpc } = load('src/main/ipc.ts')
const { addToPlaylist } = load('src/main/services/library.ts')
const delay = (ms) => new Promise((r) => setTimeout(r, ms))
app.whenReady().then(async () => {
  let win
  try {
    protocol.handle('media', mediaHandler)
    registerIpc()
    for (const item of manifest.outputs) addToPlaylist(item.source, item.name)
    win = new BrowserWindow({ show: false, webPreferences: { preload: resolve('out/preload/index.js'), sandbox: false, contextIsolation: true, nodeIntegration: false } })
    await win.loadFile(resolve('out/renderer/index.html'))
    await delay(300)
    for (const item of manifest.outputs) {
      await win.webContents.executeJavaScript(`(() => {
        const item = [...document.querySelectorAll('.sidebar-item-title')].find(e => e.title === ${JSON.stringify(item.source)});
        if (!item) throw new Error('Missing playlist entry'); item.click();
      })()`)
      let state
      for (let n = 0; n < 150; n++) {
        state = await win.webContents.executeJavaScript(`(() => {
          const v = document.querySelector('video');
          return { src: v?.currentSrc, time: v?.currentTime, ready: v?.readyState, error: v?.error?.message,
            status: document.querySelector('.status')?.textContent, active: document.querySelector('.sidebar-item.active .sidebar-item-title')?.title };
        })()`)
        if (state.time > 0.1 && state.ready >= 2) break
        await delay(100)
      }
      assert.equal(state.active, item.source)
      assert.ok(state.time > 0.1 && state.ready >= 2, `${item.name}: ${JSON.stringify(state)}`)
      assert.ok(!state.error, `${item.name}: ${state.error}`)
      await win.webContents.executeJavaScript(`new Promise((resolve, reject) => {
        const v = document.querySelector('video'); v.pause();
        const timer = setTimeout(() => reject(new Error('seek timeout')), 4000);
        v.addEventListener('seeked', () => { clearTimeout(timer); resolve(v.currentTime); }, { once: true });
        v.currentTime = Math.min(0.8, v.duration / 2);
      })`)
      console.log(`PASS renderer auto-open/play/seek: ${item.name}`)
    }
    // Fault injection exercises device-dependent decode failure after direct/remux startup.
    for (const name of ['normal.mp4', 'copy.mkv']) {
      const item = manifest.outputs.find((o) => o.name === name)
      await win.webContents.executeJavaScript(`(() => {
        [...document.querySelectorAll('.sidebar-item-title')].find(e => e.title === ${JSON.stringify(item.source)}).click();
      })()`)
      await delay(500)
      await win.webContents.executeJavaScript(`(() => {
        const v = document.querySelector('video');
        Object.defineProperty(v, 'error', { value: { code: 4 }, configurable: true });
        v.dispatchEvent(new Event('error'));
      })()`)
      let src
      for (let n = 0; n < 100; n++) {
        src = await win.webContents.executeJavaScript(`document.querySelector('video')?.currentSrc`)
        if (src?.includes('.transcode.mp4')) break
        await delay(100)
      }
      assert.ok(src?.includes('.transcode.mp4'), `${name}: fallback did not upgrade the cache: ${src}`)
      console.log(`PASS decode failure automatically upgrades ${name} to full transcode`)
    }
    await win.webContents.executeJavaScript(`(() => {
      const v = document.querySelector('video');
      Object.defineProperty(v, 'error', { value: { code: 4 }, configurable: true });
      v.dispatchEvent(new Event('error'));
    })()`)
    await delay(200)
    const failure = await win.webContents.executeJavaScript(`document.querySelector('.status')?.textContent`)
    assert.match(failure, /兼容转换后仍无法播放/)
    console.log('PASS terminal decode failure stops retrying and shows an error')
    // Rapid selection must not let an old probe/subtitle/history result replace the new file.
    const last = manifest.outputs[0]
    await win.webContents.executeJavaScript(`(() => {
      const items = [...document.querySelectorAll('.sidebar-item-title')];
      items.find(e => e.title === ${JSON.stringify(manifest.outputs[2].source)}).click();
      items.find(e => e.title === ${JSON.stringify(last.source)}).click();
    })()`)
    await delay(500)
    const source = await win.webContents.executeJavaScript(`document.querySelector('video')?.currentSrc`)
    assert.equal(source, 'media://f/' + encodeURIComponent(last.source))
    console.log('PASS rapid switching retains the newest source')
    win.destroy()
    cache.cancelConvert()
    app.exit(0)
  } catch (err) {
    console.error(err)
    win?.destroy()
    cache.cancelConvert()
    app.exit(1)
  }
})

