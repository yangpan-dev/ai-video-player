// Run after building: MEDIA_TEST_MANIFEST=/tmp/... node --test tests/media.test.cjs
// then MEDIA_TEST_MANIFEST=/tmp/... electron tests/playback-smoke.cjs
const electron = require('electron')
const { app, BrowserWindow, protocol } = electron
const { readFileSync, mkdtempSync, writeFileSync, existsSync } = require('node:fs')
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
    win = new BrowserWindow({ width: 1280, height: 820, show: false, webPreferences: { preload: resolve('out/preload/index.js'), sandbox: false, contextIsolation: true, nodeIntegration: false } })
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

    const select = async (source) => {
      await win.webContents.executeJavaScript(`(() => {
        [...document.querySelectorAll('.sidebar-item-title')].find(e => e.title === ${JSON.stringify(source)}).click();
      })()`)
      for (let n = 0; n < 100; n++) {
        if (await win.webContents.executeJavaScript(`!!document.querySelector('video')?.readyState`)) break
        await delay(50)
      }
      await win.webContents.executeJavaScript(`document.querySelector('video').pause()`)
    }
    // Import through the real preload/IPC/dialog path, with a deterministic file choice.
    const subtitle = join(manifest.dir, 'imported.vtt')
    writeFileSync(subtitle, 'WEBVTT\n\n00:00.000 --> 00:04.000\nImported line one\n第二行字幕')
    electron.dialog.showOpenDialog = async () => ({ canceled: false, filePaths: [subtitle] })
    await win.webContents.executeJavaScript(`(() => {
      [...document.querySelectorAll('button')].find(e => e.textContent.trim() === '导入字幕').click();
    })()`)
    await delay(200)
    assert.match(await win.webContents.executeJavaScript(`document.querySelector('.subtitle-overlay')?.textContent`), /Imported line one\s+第二行字幕/)
    console.log('PASS external subtitles import through the UI with all lines preserved')

    await win.webContents.executeJavaScript(`(() => {
      const volume = document.querySelector('input[title="音量"]'); volume.value = '0.35'; volume.dispatchEvent(new Event('input', { bubbles: true }));
      [...document.querySelectorAll('.speed-grid button')].find(e => e.textContent.trim() === '1.5x').click();
      document.querySelector('button[aria-label="切换静音"]').click();
    })()`)
    await select(manifest.outputs.find(o => o.name === 'av1.mp4').source)
    let settings = await win.webContents.executeJavaScript(`(() => { const v = document.querySelector('video'); return { volume: v.volume, rate: v.playbackRate, muted: v.muted }; })()`)
    assert.deepEqual(settings, { volume: 0.35, rate: 1.5, muted: true })
    await win.loadFile(resolve('out/renderer/index.html'))
    await delay(150)
    await select(last.source)
    settings = await win.webContents.executeJavaScript(`(() => { const v = document.querySelector('video'); return { volume: v.volume, rate: v.playbackRate, muted: v.muted }; })()`)
    assert.deepEqual(settings, { volume: 0.35, rate: 1.5, muted: true })
    console.log('PASS preferences survive source changes and renderer reload')

    await win.webContents.executeJavaScript(`(() => {
      const input = document.querySelector('input[aria-label="搜索视频"]'); input.value = 'surround'; input.dispatchEvent(new Event('input', { bubbles: true }));
    })()`)
    await delay(50)
    assert.equal(await win.webContents.executeJavaScript(`document.querySelectorAll('.sidebar-item').length`), 1)
    await win.webContents.executeJavaScript(`(() => {
      const input = document.querySelector('input[aria-label="搜索视频"]'); input.value = ''; input.dispatchEvent(new Event('input', { bubbles: true }));
    })()`)
    await delay(50)
    const order = await win.webContents.executeJavaScript(`[...document.querySelectorAll('.sidebar-item-title')].map(e => e.title)`)
    await select(order[0])
    await win.webContents.executeJavaScript(`(() => {
      const input = document.querySelector('.settings input[type="checkbox"]'); input.click();
      document.querySelector('video').dispatchEvent(new Event('ended'));
    })()`)
    await delay(400)
    assert.equal(await win.webContents.executeJavaScript(`document.querySelector('.sidebar-item.active .sidebar-item-title')?.title`), order[1])
    assert.equal(await win.webContents.executeJavaScript(`window.api.getProgress(${JSON.stringify(order[0])})`), 0)
    await win.webContents.executeJavaScript(`document.querySelector('.settings input[type="checkbox"]').click()`)
    console.log('PASS search, automatic next episode and completion progress reset')

    // Artificially delay an old AI task and its translation across a source switch.
    let oldRequest
    let finishRecognition
    let finishTranslation
    electron.ipcMain.removeHandler('stream:start')
    electron.ipcMain.handle('stream:start', (event, path, options) => {
      oldRequest = options.requestId
      for (let i = 0; i < 3; i++) event.sender.send('stream:segment', { requestId: oldRequest, data: { index: i, start: 0, end: 4, text: 'Old source ' + i } })
      return new Promise(resolve => { finishRecognition = resolve })
    })
    electron.ipcMain.removeHandler('llm:translate')
    electron.ipcMain.handle('llm:translate', () => new Promise(resolve => { finishTranslation = resolve }))
    await win.webContents.executeJavaScript(`(() => {
      [...document.querySelectorAll('button')].find(e => e.textContent.trim() === '开始实时识别').click();
    })()`)
    await delay(150)
    assert.ok(oldRequest && finishTranslation)
    await select(last.source)
    await win.webContents.executeJavaScript(`(() => {
      [...document.querySelectorAll('button')].find(e => e.textContent.trim() === '导入字幕').click();
    })()`)
    await delay(100)
    win.webContents.send('stream:segment', { requestId: oldRequest, data: { index: 0, start: 0, end: 4, text: 'STALE' } })
    finishTranslation(['STALE TRANSLATION', 'STALE TRANSLATION', 'STALE TRANSLATION'])
    finishRecognition({ detectedLanguage: 'ja', segmentCount: 3 })
    await delay(200)
    const subtitleText = await win.webContents.executeJavaScript(`document.querySelector('.subtitle-overlay')?.textContent`)
    assert.match(subtitleText, /Imported line one/)
    assert.doesNotMatch(subtitleText, /STALE|Old source/)
    console.log('PASS stale AI segments, translations and task completion cannot overwrite the new source')

    await select(manifest.outputs.find(o => o.name === 'hevc.mp4').source)
    const playingCache = await win.webContents.executeJavaScript(`(async () => {
      const path = decodeURIComponent(document.querySelector('video').currentSrc.slice('media://f/'.length));
      await window.api.cancelConvert();
      await window.api.clearCache();
      return path;
    })()`)
    assert.match(playingCache, /\.transcode\.mp4$/)
    assert.ok(existsSync(playingCache), 'cancelling a task must keep the playing cache protected')
    console.log('PASS cancelling through preload/IPC preserves the currently playing cache')

    win.show()
    win.focus()
    await win.webContents.executeJavaScript(`document.querySelector('.player').requestFullscreen()`, true)
    await delay(1500)
    const cursors = () => win.webContents.executeJavaScript(`(() => {
      return ['.player', 'video', '.control-bar button', '.seek', '.vol-slider'].map(selector => getComputedStyle(document.querySelector(selector)).cursor);
    })()`)
    assert.equal(await win.webContents.executeJavaScript(`document.fullscreenElement === document.querySelector('.player')`), true)
    // macOS 全屏动画可能产生额外 mousemove，等动画稳定后再计时。
    for (let n = 0; n < 80; n++) {
      if ((await cursors()).every(cursor => cursor === 'none')) break
      await delay(100)
    }
    assert.deepEqual(await cursors(), Array(5).fill('none'))
    let mouseOffset = 0
    const moveMouse = async () => {
      const point = await win.webContents.executeJavaScript(`(() => {
        const rect = document.querySelector('video').getBoundingClientRect();
        return { x: Math.round(rect.x + rect.width / 2), y: Math.round(rect.y + rect.height / 2) };
      })()`)
      win.webContents.sendInputEvent({ type: 'mouseMove', x: point.x + mouseOffset++, y: point.y })
      await delay(50)
    }
    await moveMouse()
    assert.ok((await cursors()).every(cursor => cursor !== 'none'))
    await delay(1500)
    await moveMouse()
    await delay(1500)
    assert.ok((await cursors()).every(cursor => cursor !== 'none'), 'movement must restart the idle timer')
    await delay(1300)
    assert.deepEqual(await cursors(), Array(5).fill('none'))
    await win.webContents.executeJavaScript(`document.exitFullscreen()`)
    await delay(150)
    assert.ok((await cursors()).every(cursor => cursor !== 'none'))
    win.hide()
    console.log('PASS fullscreen hides all cursors, movement resets the idle timer and exit restores cursors')
    if (process.env.UI_SCREENSHOT) {
      await win.webContents.executeJavaScript(`document.querySelector('.player').dispatchEvent(new MouseEvent('mousemove', { bubbles: true }))`)
      await delay(300)
      writeFileSync(process.env.UI_SCREENSHOT, (await win.webContents.capturePage()).toPNG())
    }
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
