export interface LyricWord {
  text: string;
  start: number;
  end: number;
}

export interface LyricLine {
  text: string;
  start: number;
  end: number;
  words: LyricWord[];
  // true: ordinary line-level LRC, equally spaced character animation only.
  // false: enhanced LRC supplied actual word timestamps.
  estimated: boolean;
}

interface ParsedLine {
  start: number;
  shift: number;
  body: string;
}

interface WordMark {
  start: number;
  begin: number;
  end: number;
}

// Explicit UTF-16 handling keeps emoji intact on ArkTS runtimes whose Array.from
// string conversion follows code units instead of the ECMAScript string iterator.
function lyricCharacters(text: string): string[] {
  const result: string[] = [];
  let index = 0;
  while (index < text.length) {
    const high = text.charCodeAt(index);
    if (high >= 0xD800 && high <= 0xDBFF && index + 1 < text.length) {
      const low = text.charCodeAt(index + 1);
      if (low >= 0xDC00 && low <= 0xDFFF) {
        result.push(text.slice(index, index + 2));
        index += 2;
        continue;
      }
    }
    result.push(text.charAt(index));
    index++;
  }
  return result;
}

function stamp(minutes: string, seconds: string, fraction: string): number {
  const second = Number(seconds);
  if (second >= 60) {
    return -1;
  }
  return Number(minutes) * 60000 + second * 1000 + Number((fraction + '000').slice(0, 3));
}

// Supported: [mm:ss], .d/.dd/.ddd, multiple line stamps, [offset:+/-ms],
// and enhanced <mm:ss.dd>word markers. Metadata and untimed text are ignored.
// Positive offsets delay the display; negative offsets advance it.
export function parseLrc(source: string, duration: number = 0): LyricLine[] {
  const finiteDuration = Number.isFinite(duration) && duration > 0 ? duration : 0;
  const offsets = /\[offset:\s*([+-]?\d+)\s*\]/gi;
  let offset = 0;
  let offsetMatch = offsets.exec(source);
  while (offsetMatch !== null) {
    const candidate = Number(offsetMatch[1]);
    if (Number.isFinite(candidate)) {
      offset = candidate;
    }
    offsetMatch = offsets.exec(source);
  }
  const parsed: ParsedLine[] = [];
  const rawLines = source.replace(/\r/g, '').split('\n');
  rawLines.forEach((raw: string) => {
    const tag = /\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]/g;
    const stamps: number[] = [];
    let bodyBegin = 0;
    let match = tag.exec(raw);
    while (match !== null) {
      // A timestamp belongs to the leading label sequence, not text in the lyric.
      if (raw.slice(bodyBegin, match.index).trim().length > 0) {
        break;
      }
      const time = stamp(match[1], match[2], match[3] ?? '');
      if (time >= 0) {
        stamps.push(time);
      }
      bodyBegin = match.index + match[0].length;
      match = tag.exec(raw);
    }
    if (stamps.length === 0) {
      return;
    }
    const body = raw.slice(bodyBegin).trim();
    stamps.forEach((start: number) => {
      if (finiteDuration > 0 && start + offset >= finiteDuration) {
        return;
      }
      parsed.push({ start: Math.max(0, start + offset), shift: start - stamps[0] + offset, body: body });
    });
  });
  parsed.sort((a: ParsedLine, b: ParsedLine) => a.start - b.start);
  const result: LyricLine[] = [];
  parsed.forEach((item: ParsedLine, index: number) => {
    let end = finiteDuration > 0 ? finiteDuration : item.start + 5000;
    for (let next = index + 1; next < parsed.length; next++) {
      if (parsed[next].start > item.start) {
        end = parsed[next].start;
        break;
      }
    }
    if (finiteDuration > 0) {
      end = Math.min(end, finiteDuration);
    }
    end = Math.max(item.start, end);
    const marks: WordMark[] = [];
    const wordTag = /<(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?>/g;
    let wordMatch = wordTag.exec(item.body);
    while (wordMatch !== null) {
      const time = stamp(wordMatch[1], wordMatch[2], wordMatch[3] ?? '');
      if (time >= 0) {
        // Repeated line timestamps shift enhanced markers by the same amount.
        const adjusted = time + item.shift;
        marks.push({ start: Math.max(item.start, Math.min(end, adjusted)),
          begin: wordMatch.index, end: wordMatch.index + wordMatch[0].length });
      }
      wordMatch = wordTag.exec(item.body);
    }
    const text = item.body.replace(/<\d{1,3}:\d{2}(?:[.:]\d{1,3})?>/g, '');
    const words: LyricWord[] = [];
    // Non-monotonic markers or untimed prefix are malformed; use honest estimation.
    const validMarks = marks.length > 0 && item.body.slice(0, marks[0].begin).trim().length === 0 &&
      marks.every((mark: WordMark, at: number) => at === 0 || mark.start >= marks[at - 1].start);
    if (validMarks) {
      marks.forEach((mark: WordMark, at: number) => {
        const wordText = item.body.slice(mark.end, at + 1 < marks.length ? marks[at + 1].begin : item.body.length);
        if (wordText.length > 0) {
          words.push({ text: wordText, start: mark.start, end: at + 1 < marks.length ? marks[at + 1].start : end });
        }
      });
    } else {
      // Preserve surrogate pairs such as emoji in both ArkTS and Node.
      const characters = lyricCharacters(text);
      characters.forEach((character: string, at: number) => {
        words.push({ text: character, start: item.start + (end - item.start) * at / characters.length,
          end: item.start + (end - item.start) * (at + 1) / characters.length });
      });
    }
    result.push({ text: text, start: item.start, end: end, words: words, estimated: !validMarks });
  });
  return result;
}

export function findLyricIndex(lines: LyricLine[], position: number): number {
  if (!Number.isFinite(position) || position < 0) {
    return -1;
  }
  let left = 0;
  let right = lines.length - 1;
  let found = -1;
  while (left <= right) {
    const middle = Math.floor((left + right) / 2);
    if (lines[middle].start <= position) {
      found = middle;
      left = middle + 1;
    } else {
      right = middle - 1;
    }
  }
  return found;
}

export function wordProgress(word: LyricWord, position: number): number {
  if (!Number.isFinite(position) || position < word.start) {
    return 0;
  }
  if (word.end <= word.start) {
    return 1;
  }
  return Math.max(0, Math.min(1, (position - word.start) / (word.end - word.start)));
}

