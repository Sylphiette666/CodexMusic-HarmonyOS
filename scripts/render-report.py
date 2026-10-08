"""Rasterize a locally exported PDF using only the selected bundled Poppler.

Called by render-report.ps1. Intermediates stay in the QA output directory.
No artifact authoring or mark operation occurs in this read-only renderer.
"""
from __future__ import annotations
import argparse
import json
import re
import subprocess
from pathlib import Path
from PIL import Image


def run(command: list[str]) -> str:
    result = subprocess.run(command, check=True, capture_output=True, text=True,
                            encoding='utf-8', errors='replace', timeout=120,
                            creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    return result.stdout


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('pdf', type=Path)
    parser.add_argument('--output-dir', required=True, type=Path)
    parser.add_argument('--poppler-bin', required=True, type=Path)
    parser.add_argument('--dpi', type=int, default=150)
    parser.add_argument('--engine', required=True)
    parser.add_argument('--source-docx', required=True, type=Path)
    parser.add_argument('--source-sha256', required=True)
    args = parser.parse_args()
    if not 72 <= args.dpi <= 300:
        raise ValueError('DPI must be 72 through 300.')
    pdf = args.pdf.resolve(strict=True)
    output = args.output_dir.resolve(strict=True)
    binaries = args.poppler_bin.resolve(strict=True)
    info = run([str(binaries / 'pdfinfo.exe'), str(pdf)])
    (output / 'pdfinfo.txt').write_text(info, encoding='utf-8')
    match = re.search(r'^Pages:\s+(\d+)\s*$', info, re.MULTILINE)
    if not match:
        raise RuntimeError('Poppler did not report a page count.')
    count = int(match.group(1))
    if count < 1:
        raise RuntimeError('The exported PDF has no pages.')
    run([str(binaries / 'pdftoppm.exe'), '-png', '-r', str(args.dpi), str(pdf), str(output / 'page')])
    pages = []
    for page in sorted(output.glob('page-*.png'), key=lambda p: int(p.stem.split('-')[-1])):
        number = int(page.stem.split('-')[-1])
        canonical = output / f'page-{number}.png'
        if page != canonical:
            page.rename(canonical)
        with Image.open(canonical) as bitmap:
            bitmap.load()
            width, height = bitmap.size
        if width < 100 or height < 100:
            raise RuntimeError(f'Invalid raster size: {canonical}')
        pages.append({'number': number, 'path': str(canonical), 'width': width, 'height': height})
    if len(pages) != count or [p['number'] for p in pages] != list(range(1, count + 1)):
        raise RuntimeError('Raster pages do not match the exported PDF page count.')
    manifest = {'engine': args.engine, 'source_docx': str(args.source_docx.resolve(strict=True)),
                'source_sha256': args.source_sha256, 'pdf': str(pdf), 'page_count': count,
                'dpi': args.dpi, 'pages': pages,
                'visual_inspection_required': True,
                'note': 'Rendering verified; a human or image-capable agent must inspect every page.'}
    (output / 'render-manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    print(f'Exported {count} PDF pages and verified {len(pages)} PNG files at {args.dpi} DPI.')


if __name__ == '__main__':
    main()
