/* Tests service behavior against real temporary files and mocked Harmony APIs.
 * Actual codec/Picker interoperability still requires a HarmonyOS device.
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const studio = process.env.DEVECO_HOME || 'D:\\HUAWEI\\DevEco Studio';
const ts = require(path.join(studio, 'tools', 'ohpm', 'node_modules', 'typescript'));
const sourceFile = path.resolve(__dirname, '../entry/src/main/ets/services/ImportService.ets');
const compiled = ts.transpileModule(fs.readFileSync(sourceFile, 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS },
  reportDiagnostics: true
});
assert.equal((compiled.diagnostics || []).length, 0, 'TypeScript syntax diagnostics');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-music-import-'));
const sandbox = path.join(temp, 'app');
const input = path.join(temp, 'input');
fs.mkdirSync(sandbox);
fs.mkdirSync(input);
let selection = [];
let folderSupported = false;
let deviceType = 'phone';
let pickerCalls = 0;
let oversized = '';
let extractCount = 0;
let released = 0;
let coverEnabled = false;
const descriptors = new Set();
const fakeFs = {
  OpenMode: { READ_ONLY: 0, WRITE_ONLY: 1, CREATE: 2, TRUNC: 4 },
  async access(p) { return fs.existsSync(p); },
  async mkdir(p) { fs.mkdirSync(p, { recursive: true }); },
  async open(p, mode) {
    const fd = fs.openSync(p, mode === 0 ? 'r' : 'w');
    descriptors.add(fd);
    return { fd, path: p, name: path.basename(p) };
  },
  async close(fd) { fs.closeSync(fd); descriptors.delete(fd); },
  async stat(fd) {
    const stat = fs.fstatSync(fd);
    if (oversized && fs.readFileSync(oversized).equals(fs.readFileSync(fd))) {
      stat.size = 257 * 1024 * 1024;
      // Restore file pointer after readFileSync(fd) used only in this size test.
    }
    return stat;
  },
  async lstat(p) { return fs.lstatSync(p); },
  async read(fd, buffer) { return fs.readSync(fd, Buffer.from(buffer), 0, buffer.byteLength, null); },
  // Force partial writes to ensure copy/text loops preserve every byte.
  async write(fd, buffer) {
    const data = Buffer.from(buffer);
    return fs.writeSync(fd, data, 0, Math.min(12000, data.length), null);
  },
  async listFile(p, options = {}) {
    const list = fs.readdirSync(p);
    return options.listNum ? list.slice(0, options.listNum) : list;
  },
  async readText(p, options = {}) {
    const data = fs.readFileSync(p);
    return data.subarray(0, options.length || data.length).toString('utf8');
  },
  async unlink(p) { fs.unlinkSync(p); },
  async rename(a, b) { fs.renameSync(a, b); }
};
const kits = {
  '@kit.AbilityKit': {},
  '@kit.BasicServicesKit': { deviceInfo: { get deviceType() { return deviceType; } } },
  '@kit.CoreFileKit': {
    fileIo: fakeFs,
    fileUri: { FileUri: class { constructor(uri) { this.name = path.basename(uri); } } },
    hash: { async hash(p) { return crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex'); } },
    picker: {
      DocumentSelectOptions: class {}, DocumentSelectMode: { FOLDER: 1 },
      DocumentViewPicker: class { async select() { pickerCalls++; return selection; } }
    }
  },
  '@kit.ArkTS': {
    util: {
      generateRandomUUID: () => crypto.randomUUID(),
      TextEncoder: class { encodeInto(s) { return new TextEncoder().encode(s); } },
      TextDecoder: { create(encoding, options) {
        return { decodeToString(data) { return new TextDecoder(encoding, options).decode(data); } };
      } }
    }
  },
  '@kit.MediaKit': { media: { async createAVMetadataExtractor() {
    return {
      fdSrc: null,
      async fetchMetadata() {
        extractCount++;
        const bytes = fs.readFileSync(this.fdSrc.fd).toString();
        if (!bytes.startsWith('VALID:')) throw new Error('Unsupported format');
        return { title: bytes.includes('TAGGED') ? '标签歌曲' : '', artist: '', album: '', duration: '24000' };
      },
      async fetchAlbumCover() {
        if (!coverEnabled) throw new Error('No cover');
        return {
          async getImageInfo() { return { size: { width: 1000, height: 1000 } }; },
          async scale(x, y) { assert.equal(x, 0.72); assert.equal(y, 0.72); },
          async release() {}
        };
      },
      async release() { released++; }
    };
  } } },
  '@kit.ImageKit': { image: { createImagePacker() {
    return {
      async packToFile(pixels, fd) { fs.writeSync(fd, Buffer.from('JPEG')); },
      async release() {}
    };
  } } },
  '../model/MusicModels': {}
};
const moduleExports = {};
vm.runInNewContext(compiled.outputText, {
  exports: moduleExports,
  require(name) { assert.ok(kits[name], 'Unexpected platform dependency ' + name); return kits[name]; },
  canIUse: () => folderSupported,
  Uint8Array, ArrayBuffer, Number, Map, Set, Error
}, { filename: sourceFile });
const service = new moduleExports.ImportService({ filesDir: sandbox });
const put = (name, value) => {
  const p = path.join(input, name);
  fs.writeFileSync(p, value);
  return p;
};
let tests = 0;
const test = async (name, body) => { await body(); tests++; console.log('PASS ' + name); };
(async () => {
  try {
    await test('picker cancellation is distinct from failure', async () => {
      selection = [];
      const result = await service.importAudio();
      assert.equal(result.cancelled, true);
      assert.equal(result.errors.length, 0);
    });
    await test('unsupported phone folder access is explicit', async () => {
      const result = await service.scanDirectory();
      assert.equal(result.songs.length, 0);
      assert.match(result.errors[0], /不支持文件夹授权/);
    });
    await test('API 24 phone/tablet cannot open folder picker even when syscap reports true', async () => {
      folderSupported = true;
      const before = pickerCalls;
      for (const type of ['phone', 'tablet']) {
        deviceType = type;
        const result = await service.scanDirectory();
        assert.equal(result.cancelled, false);
        assert.equal(result.songs.length, 0);
        assert.match(result.errors[0], /不支持文件夹授权/);
      }
      assert.equal(pickerCalls, before, 'FOLDER request must not reach ignored phone/tablet Picker');
      deviceType = 'phone';
      folderSupported = false;
    });
    await test('2in1 also requires directory-selection syscap', async () => {
      deviceType = '2in1';
      folderSupported = false;
      const before = pickerCalls;
      const result = await service.scanDirectory();
      assert.match(result.errors[0], /不支持文件夹授权/);
      assert.equal(pickerCalls, before);
      deviceType = 'phone';
    });
    let first;
    const audio = put('夜色.wav', 'VALID:' + 'tone'.repeat(100000));
    const lyrics = put('夜色.lrc', '[00:00.00]夜色\n[00:02.00]流动');
    await test('copy survives partial writes and associates selected LRC', async () => {
      selection = [audio, lyrics];
      const result = await service.importAudio();
      assert.equal(result.errors.length, 0);
      assert.equal(result.songs.length, 1);
      first = result.songs[0];
      assert.equal(first.title, '夜色');
      assert.equal(first.duration, 24000);
      assert.equal(first.artist, '未知歌手');
      assert.equal(first.lyrics, fs.readFileSync(lyrics, 'utf8'));
      assert.deepEqual(fs.readFileSync(first.uri), fs.readFileSync(audio));
      assert.match(first.id, /^[a-f0-9]{64}$/);
      assert.ok(!fs.readdirSync(path.dirname(first.uri)).some(n => n.endsWith('.part')));
    });
    await test('identical content is deduplicated across filenames and extensions', async () => {
      const duplicate = put('duplicate.mp3', fs.readFileSync(audio));
      selection = [audio, duplicate];
      const result = await service.importAudio();
      assert.equal(result.songs.length, 1);
      assert.equal(result.songs[0].id, first.id);
      assert.equal(result.songs[0].uri, first.uri);
      const files = fs.readdirSync(path.dirname(first.uri)).filter(n => /\.(wav|mp3)$/.test(n));
      assert.equal(files.length, 1);
    });
    await test('rescan retains identity and saved lyrics', async () => {
      await service.saveLyrics(first, '[00:00.00]新歌词');
      const result = await service.scanImported();
      assert.equal(result.errors.length, 0);
      assert.equal(result.songs[0].id, first.id);
      assert.equal(result.songs[0].title, '夜色');
      assert.equal(result.songs[0].lyrics, '[00:00.00]新歌词');
    });
    await test('failed decoding removes copied audio and all attachments', async () => {
      selection = [put('broken.mp3', 'BROKEN')];
      const before = fs.readdirSync(path.dirname(first.uri));
      const result = await service.importAudio();
      assert.equal(result.songs.length, 0);
      assert.match(result.errors[0], /Unsupported format/);
      assert.deepEqual(fs.readdirSync(path.dirname(first.uri)), before);
    });
    await test('metadata tag and extracted cover are persisted', async () => {
      coverEnabled = true;
      selection = [put('tagged.wav', 'VALID:TAGGED')];
      const result = await service.importAudio();
      assert.equal(result.songs[0].title, '标签歌曲');
      assert.equal(fs.readFileSync(result.songs[0].cover, 'utf8'), 'JPEG');
      coverEnabled = false;
    });
    await test('huge files are rejected before copying', async () => {
      oversized = put('huge.wav', 'PRETEND_OVERSIZED');
      selection = [oversized];
      const result = await service.importAudio();
      oversized = '';
      assert.equal(result.songs.length, 0);
      assert.match(result.errors[0], /256 MB/);
    });
    await test('lyrics cancellation, invalid LRC, and UTF-16 handling', async () => {
      selection = [];
      assert.equal(await service.importLyrics(), '');
      selection = [put('bad.lrc', 'no timestamps')];
      await assert.rejects(service.importLyrics(), /时间标签/);
      selection = [put('utf16.lrc', Buffer.from('\uFEFF[00:00.00]中文', 'utf16le'))];
      assert.equal(await service.importLyrics(), '[00:00.00]中文');
      selection = [put('invalid-utf8.lrc', Buffer.from([0xff, 0x80, 0x80]))];
      await assert.rejects(service.importLyrics(), /UTF-8/);
    });
    await test('authorized directory scan finds nested audio and matching LRC', async () => {
      deviceType = '2in1';
      folderSupported = true;
      const folder = path.join(input, 'album');
      const nested = path.join(folder, 'disc');
      fs.mkdirSync(nested, { recursive: true });
      fs.writeFileSync(path.join(nested, 'dawn.wav'), 'VALID:NESTED');
      fs.writeFileSync(path.join(nested, 'dawn.lrc'), '[00:00.00]晨光');
      selection = [folder];
      const result = await service.scanDirectory();
      assert.equal(result.errors.length, 0);
      assert.equal(result.songs.length, 1);
      assert.equal(result.songs[0].lyrics, '[00:00.00]晨光');
    });
    await test('delete rejects outside/traversal paths and preserves original files', async () => {
      await assert.rejects(service.removeImported({ ...first, uri: audio }), /仅允许/);
      await assert.rejects(service.removeImported({ ...first, uri: sandbox + '/music/../outside.wav' }), /仅允许/);
      await service.removeImported(first);
      assert.equal(fs.existsSync(first.uri), false);
      assert.equal(fs.existsSync(audio), true);
    });
    await test('all native descriptors/extractors are released on success and errors', async () => {
      assert.equal(descriptors.size, 0);
      assert.equal(released, extractCount);
    });
    console.log(`${tests} import-service behavior tests passed (platform APIs mocked).`);
  } finally {
    assert.ok(path.resolve(temp).startsWith(path.resolve(os.tmpdir()) + path.sep));
    assert.ok(path.basename(temp).startsWith('codex-music-import-'));
    fs.rmSync(temp, { recursive: true, force: true });
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
