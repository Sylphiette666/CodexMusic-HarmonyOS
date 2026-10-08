import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { fileIo as fs, fileUri, hash, picker } from '@kit.CoreFileKit';
import { media } from '@kit.MediaKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { Song } from '../model/MusicModels';

const AUDIO_EXTENSIONS: string[] = ['mp3', 'm4a', 'aac', 'wav', 'flac', 'ogg', 'amr'];
const MAX_AUDIO_BYTES: number = 256 * 1024 * 1024;
const MAX_BATCH_BYTES: number = 512 * 1024 * 1024;
const MAX_LYRIC_BYTES: number = 1024 * 1024;
const MAX_SCAN_FILES: number = 5000;
const MAX_IMPORT_SONGS: number = 500;

export class ImportResult {
  songs: Song[] = [];
  errors: string[] = [];
  cancelled: boolean = false;
}

class ImportCandidate {
  uri: string = '';
  name: string = '';
  lyricUri: string = '';
}

function extension(name: string): string {
  const dot: number = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
}

function withoutExtension(name: string): string {
  const dot: number = name.lastIndexOf('.');
  return dot < 0 ? name : name.substring(0, dot);
}

function describeError(error: Error): string {
  return error.message.length > 0 ? error.message : String(error);
}

/** Only user-selected files and the app's own music directory are accessed. */
export class ImportService {
  private context: common.UIAbilityContext;
  private directory: string;
  private busy: boolean = false;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.directory = context.filesDir + '/music';
  }

  async importAudio(): Promise<ImportResult> {
    const result: ImportResult = new ImportResult();
    if (this.busy) {
      result.errors.push('正在导入，请等待当前操作完成');
      return result;
    }
    this.busy = true;
    try {
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 100;
      options.fileSuffixFilters = ['音频和歌词|.mp3,.m4a,.aac,.wav,.flac,.ogg,.amr,.lrc'];
      const selected: string[] = await new picker.DocumentViewPicker(this.context).select(options);
      result.cancelled = selected.length === 0;
      const candidates: ImportCandidate[] = [];
      const lyrics: Map<string, string> = new Map<string, string>();
      for (const uri of selected) {
        const name: string = new fileUri.FileUri(uri).name;
        if (extension(name) === 'lrc') {
          lyrics.set(withoutExtension(name).toLowerCase(), uri);
        } else if (AUDIO_EXTENSIONS.includes(extension(name))) {
          const item: ImportCandidate = new ImportCandidate();
          item.uri = uri;
          item.name = name;
          candidates.push(item);
        } else {
          result.errors.push(name + '：不是支持的音频格式');
        }
      }
      for (const item of candidates) {
        item.lyricUri = lyrics.get(withoutExtension(item.name).toLowerCase()) ?? '';
      }
      if (selected.length > 0 && candidates.length === 0) {
        result.errors.push('未选择音频。单独导入歌词请使用播放页的“导入歌词”');
      }
      await this.importCandidates(candidates, result);
    } catch (error) {
      result.errors.push('导入失败：' + describeError(error as Error));
    } finally {
      this.busy = false;
    }
    return result;
  }

  async scanDirectory(): Promise<ImportResult> {
    const result: ImportResult = new ImportResult();
    // API 24 phones can report this syscap while silently ignoring FOLDER mode.
    // Keep the SDK's 2in1 device restriction as well as its capability check.
    // Do not assume unverified later phone/tablet SDKs enable this flow.
    if (deviceInfo.deviceType !== '2in1' ||
      !canIUse('SystemCapability.FileManagement.UserFileService.FolderSelection')) {
      result.errors.push('当前 API 24 配置下此设备不支持文件夹授权，仅支持具备目录能力的 2in1。请用“导入音频”多选文件，或“扫描本应用”扫描已导入的音乐');
      return result;
    }
    if (this.busy) {
      result.errors.push('正在导入，请等待当前操作完成');
      return result;
    }
    this.busy = true;
    let folder: fs.File | undefined = undefined;
    try {
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.selectMode = picker.DocumentSelectMode.FOLDER;
      options.maxSelectNumber = 1;
      const selected: string[] = await new picker.DocumentViewPicker(this.context).select(options);
      if (selected.length === 0) {
        result.cancelled = true;
        return result;
      }
      folder = await fs.open(selected[0], fs.OpenMode.READ_ONLY);
      const info: fs.Stat = await fs.stat(folder.fd);
      if (!info.isDirectory()) {
        throw new Error('系统未返回可访问的文件夹，请改用多选音频');
      }
      const paths: string[] = [];
      await this.walkDirectory(folder.path, paths, result, 0);
      const candidates: ImportCandidate[] = this.directoryCandidates(paths);
      await this.importCandidates(candidates, result);
      if (candidates.length === 0) {
        result.errors.push('授权文件夹内未发现支持的音频文件');
      }
    } catch (error) {
      result.errors.push('目录扫描失败：' + describeError(error as Error));
    } finally {
      if (folder !== undefined) {
        await fs.close(folder.fd).catch(() => {});
      }
      this.busy = false;
    }
    return result;
  }

  async scanImported(): Promise<ImportResult> {
    const result: ImportResult = new ImportResult();
    if (this.busy) {
      result.errors.push('正在导入，请等待当前操作完成');
      return result;
    }
    this.busy = true;
    try {
      await this.ensureDirectory();
      const names: string[] = await fs.listFile(this.directory, { listNum: MAX_SCAN_FILES + 1 });
      if (names.length > MAX_SCAN_FILES) {
        result.errors.push('扫描条目达到 5000 个，本次只处理前 5000 个');
      }
      const candidates: ImportCandidate[] = [];
      for (const name of names.slice(0, MAX_SCAN_FILES)) {
        if (!this.isSafeChildName(name) || !AUDIO_EXTENSIONS.includes(extension(name))) {
          continue;
        }
        const path: string = this.directory + '/' + name;
        const info: fs.Stat = await fs.lstat(path);
        if (!info.isFile() || info.isSymbolicLink()) {
          continue;
        }
        const item: ImportCandidate = new ImportCandidate();
        item.uri = path;
        item.name = name;
        const stem: string = withoutExtension(path);
        if (await fs.access(stem + '.name')) {
          item.name = (await fs.readText(stem + '.name', { length: 4096 })).trim() || name;
        }
        if (await fs.access(stem + '.lrc')) {
          item.lyricUri = stem + '.lrc';
        }
        candidates.push(item);
      }
      await this.importCandidates(candidates, result);
    } catch (error) {
      result.errors.push('扫描本应用失败：' + describeError(error as Error));
    } finally {
      this.busy = false;
    }
    return result;
  }

  /** Returns LRC text. Empty string means the picker was cancelled. */
  async importLyrics(): Promise<string> {
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = ['LRC 歌词|.lrc'];
    const selected: string[] = await new picker.DocumentViewPicker(this.context).select(options);
    if (selected.length === 0) {
      return '';
    }
    const content: string = await this.readLyricUri(selected[0]);
    if (content.trim().length === 0) {
      throw new Error('歌词文件为空');
    }
    if (!/\[\d+:\d{2}(?:[.:]\d+)?\]/.test(content)) {
      throw new Error('未找到 LRC 时间标签，请使用 [00:01.00] 格式歌词');
    }
    return content;
  }

  /** UI saves Song.lyrics to its RDB; this sidecar also preserves it on rescans. */
  async saveLyrics(song: Song, text: string): Promise<void> {
    const stem: string = this.ownedStem(song.uri);
    if (new util.TextEncoder().encodeInto(text).length > MAX_LYRIC_BYTES) {
      throw new Error('歌词过大，请使用 1 MB 以内的文件');
    }
    await this.writeText(stem + '.lrc', text);
  }

  /** Never removes an original user file or a path outside the import directory. */
  async removeImported(song: Song): Promise<void> {
    const stem: string = this.ownedStem(song.uri);
    const paths: string[] = [song.uri, stem + '.name', stem + '.lrc', stem + '.jpg'];
    for (const path of paths) {
      if (await fs.access(path)) {
        await fs.unlink(path);
      }
    }
  }

  private async ensureDirectory(): Promise<void> {
    if (!(await fs.access(this.directory))) {
      await fs.mkdir(this.directory, true);
    }
  }

  private isSafeChildName(name: string): boolean {
    return name.length > 0 && name !== '.' && name !== '..' &&
      !name.includes('/') && !name.includes('\\') && !name.includes('\u0000');
  }

  private ownedStem(path: string): string {
    const prefix: string = this.directory + '/';
    if (!path.startsWith(prefix) || !this.isSafeChildName(path.substring(prefix.length)) ||
      !AUDIO_EXTENSIONS.includes(extension(path))) {
      throw new Error('仅允许修改本应用导入目录中的音频附件');
    }
    return withoutExtension(path);
  }

  private async walkDirectory(root: string, paths: string[], result: ImportResult, depth: number): Promise<void> {
    if (depth > 12 || paths.length >= MAX_SCAN_FILES) {
      result.errors.push('目录扫描达到深度或文件数量限制，请选择更小的音乐文件夹');
      return;
    }
    const names: string[] = await fs.listFile(root, { listNum: MAX_SCAN_FILES - paths.length + 1 });
    for (const name of names) {
      if (paths.length >= MAX_SCAN_FILES) {
        result.errors.push('目录扫描达到 5000 个条目的上限，请分批导入');
        return;
      }
      if (!this.isSafeChildName(name)) {
        continue;
      }
      const path: string = root + '/' + name;
      paths.push(path);
      try {
        const info: fs.Stat = await fs.lstat(path);
        if (info.isSymbolicLink()) {
          paths.pop();
        } else if (info.isDirectory()) {
          await this.walkDirectory(path, paths, result, depth + 1);
        }
      } catch (error) {
        result.errors.push(name + '：无法访问，' + describeError(error as Error));
      }
    }
  }

  private directoryCandidates(paths: string[]): ImportCandidate[] {
    const lyrics: Map<string, string> = new Map<string, string>();
    for (const path of paths) {
      if (extension(path) === 'lrc') {
        lyrics.set(withoutExtension(path).toLowerCase(), path);
      }
    }
    const candidates: ImportCandidate[] = [];
    for (const path of paths) {
      if (AUDIO_EXTENSIONS.includes(extension(path))) {
        const item: ImportCandidate = new ImportCandidate();
        item.uri = path;
        item.name = path.substring(path.lastIndexOf('/') + 1);
        item.lyricUri = lyrics.get(withoutExtension(path).toLowerCase()) ?? '';
        candidates.push(item);
      }
    }
    return candidates;
  }

  private async importCandidates(candidates: ImportCandidate[], result: ImportResult): Promise<void> {
    await this.ensureDirectory();
    let batchBytes: number = 0;
    const seen: Set<string> = new Set<string>();
    for (const item of candidates.slice(0, MAX_IMPORT_SONGS)) {
      let source: fs.File | undefined = undefined;
      let temporary: string = '';
      let created: string = '';
      try {
        source = await fs.open(item.uri, fs.OpenMode.READ_ONLY);
        const info: fs.Stat = await fs.stat(source.fd);
        if (!info.isFile() || info.size === 0) {
          throw new Error('不是有效的音频文件，或文件为空');
        }
        if (info.size > MAX_AUDIO_BYTES) {
          throw new Error('超过单文件 256 MB 限制');
        }
        batchBytes += info.size;
        if (batchBytes > MAX_BATCH_BYTES) {
          result.errors.push('本次导入达到 512 MB 限制，请将剩余文件分批导入');
          break;
        }
        // Copy before hashing: picker grants may be temporary and URI is not a
        // guaranteed local path. Read/write streams use a bounded 256 KiB buffer.
        temporary = this.directory + '/' + util.generateRandomUUID(true) + '.part';
        await this.copyBounded(source.fd, temporary, info.size);
        await fs.close(source.fd);
        source = undefined;
        const digest: string = (await hash.hash(temporary, 'sha256')).toLowerCase();
        let destination: string = this.directory + '/' + digest + '.' + extension(item.name);
        for (const ext of AUDIO_EXTENSIONS) {
          const previous: string = this.directory + '/' + digest + '.' + ext;
          if (await fs.access(previous)) {
            destination = previous;
            break;
          }
        }
        const alreadyExists: boolean = await fs.access(destination);
        if (!alreadyExists) {
          await fs.rename(temporary, destination);
          temporary = '';
          created = destination;
        }
        const song: Song = await this.extractMetadata(destination, item.name, digest, result);
        const stem: string = withoutExtension(destination);
        if (!alreadyExists) {
          await this.writeText(stem + '.name', item.name);
        }
        if (item.lyricUri.length > 0) {
          try {
            song.lyrics = await this.readLyricUri(item.lyricUri);
            await this.writeText(stem + '.lrc', song.lyrics);
          } catch (error) {
            result.errors.push(item.name + '：歌词读取失败，' + describeError(error as Error));
          }
        } else if (await fs.access(stem + '.lrc')) {
          try {
            song.lyrics = await this.readLyricUri(stem + '.lrc');
          } catch (error) {
            result.errors.push(item.name + '：已保存歌词无法读取，' + describeError(error as Error));
          }
        }
        if (!seen.has(song.id)) {
          result.songs.push(song);
          seen.add(song.id);
        }
      } catch (error) {
        result.errors.push(item.name + '：' + describeError(error as Error));
        if (created.length > 0) {
          const stem: string = withoutExtension(created);
          for (const path of [created, stem + '.name', stem + '.lrc', stem + '.jpg']) {
            await this.tryRemove(path);
          }
        }
      } finally {
        if (source !== undefined) {
          await fs.close(source.fd).catch(() => {});
        }
        if (temporary.length > 0) {
          await this.tryRemove(temporary);
        }
      }
    }
    if (candidates.length > MAX_IMPORT_SONGS) {
      result.errors.push('单次最多导入 500 首，请分批选择');
    }
  }

  private async copyBounded(sourceFd: number, path: string, expectedSize: number): Promise<void> {
    const destination: fs.File = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      const chunk: ArrayBuffer = new ArrayBuffer(256 * 1024);
      let total: number = 0;
      let count: number = await fs.read(sourceFd, chunk);
      while (count > 0) {
        total += count;
        if (total > MAX_AUDIO_BYTES || total > expectedSize) {
          throw new Error('读取时文件大小发生变化，请重新选择文件');
        }
        let written: number = 0;
        while (written < count) {
          const piece: ArrayBuffer = chunk.slice(written, count);
          const bytes: number = await fs.write(destination.fd, piece);
          if (bytes <= 0) {
            throw new Error('无法写入应用存储，请检查剩余空间');
          }
          written += bytes;
        }
        count = await fs.read(sourceFd, chunk);
      }
      if (total !== expectedSize) {
        throw new Error('文件未完整读取，请重新选择文件');
      }
    } finally {
      await fs.close(destination.fd);
    }
  }

  private async extractMetadata(path: string, name: string, id: string, result: ImportResult): Promise<Song> {
    const song: Song = {
      id: id, uri: path, fileName: name, title: withoutExtension(name), artist: '未知歌手',
      album: '未知专辑', cover: '', lyrics: '', duration: 0
    };
    const file: fs.File = await fs.open(path, fs.OpenMode.READ_ONLY);
    let extractor: media.AVMetadataExtractor | undefined = undefined;
    try {
      extractor = await media.createAVMetadataExtractor();
      const stat: fs.Stat = await fs.stat(file.fd);
      extractor.fdSrc = { fd: file.fd, offset: 0, length: stat.size };
      const metadata: media.AVMetadata = await extractor.fetchMetadata();
      song.title = metadata.title?.trim() || song.title;
      song.artist = metadata.artist?.trim() || metadata.albumArtist?.trim() || song.artist;
      song.album = metadata.album?.trim() || song.album;
      song.duration = Number(metadata.duration ?? '0');
      if (!Number.isFinite(song.duration) || song.duration <= 0 || metadata.hasAudio === 'no') {
        throw new Error('音频无有效时长、已损坏或格式不受设备支持');
      }
      song.cover = await this.extractCover(extractor, withoutExtension(path) + '.jpg', result, name);
      return song;
    } finally {
      if (extractor !== undefined) {
        await extractor.release().catch(() => {});
      }
      await fs.close(file.fd);
    }
  }

  private async extractCover(extractor: media.AVMetadataExtractor, path: string,
    result: ImportResult, name: string): Promise<string> {
    if (await fs.access(path)) {
      return path;
    }
    let pixels: image.PixelMap;
    try {
      pixels = await extractor.fetchAlbumCover();
    } catch (error) {
      // Most WAV files and many MP3s contain no embedded artwork.
      return '';
    }
    const packer: image.ImagePacker = image.createImagePacker();
    let output: fs.File | undefined = undefined;
    try {
      const info: image.ImageInfo = await pixels.getImageInfo();
      const longest: number = Math.max(info.size.width, info.size.height);
      if (longest > 720) {
        await pixels.scale(720 / longest, 720 / longest);
      }
      output = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      await packer.packToFile(pixels, output.fd, { format: 'image/jpeg', quality: 85 });
      return path;
    } catch (error) {
      result.errors.push(name + '：封面保存失败，将显示默认封面');
      await this.tryRemove(path);
      return '';
    } finally {
      if (output !== undefined) {
        await fs.close(output.fd).catch(() => {});
      }
      await pixels.release().catch(() => {});
      await packer.release().catch(() => {});
    }
  }

  private async readLyricUri(uri: string): Promise<string> {
    const file: fs.File = await fs.open(uri, fs.OpenMode.READ_ONLY);
    try {
      const stat: fs.Stat = await fs.stat(file.fd);
      if (!stat.isFile() || stat.size > MAX_LYRIC_BYTES) {
        throw new Error('歌词文件必须小于 1 MB');
      }
      const data: Uint8Array = new Uint8Array(stat.size);
      let total: number = 0;
      while (total < data.length) {
        const part: ArrayBuffer = new ArrayBuffer(data.length - total);
        const count: number = await fs.read(file.fd, part);
        if (count === 0) {
          throw new Error('歌词文件未完整读取');
        }
        data.set(new Uint8Array(part, 0, count), total);
        total += count;
      }
      let encoding: string = 'utf-8';
      if (data.length >= 2 && data[0] === 0xff && data[1] === 0xfe) {
        encoding = 'utf-16le';
      } else if (data.length >= 2 && data[0] === 0xfe && data[1] === 0xff) {
        encoding = 'utf-16be';
      }
      try {
        return util.TextDecoder.create(encoding, { fatal: true }).decodeToString(data).replace(/^\uFEFF/, '');
      } catch (error) {
        throw new Error('歌词编码无法识别，请将文件另存为 UTF-8');
      }
    } finally {
      await fs.close(file.fd);
    }
  }

  private async writeText(path: string, content: string): Promise<void> {
    const output: fs.File = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      const data: Uint8Array = new util.TextEncoder().encodeInto(content);
      let total: number = 0;
      while (total < data.length) {
        const count: number = await fs.write(output.fd, data.buffer.slice(total));
        if (count <= 0) {
          throw new Error('写入附件失败');
        }
        total += count;
      }
    } finally {
      await fs.close(output.fd);
    }
  }

  private async tryRemove(path: string): Promise<void> {
    try {
      if (await fs.access(path)) {
        await fs.unlink(path);
      }
    } catch (error) {
      // Retain the original actionable error; an orphan can be retried on rescan.
    }
  }
}
