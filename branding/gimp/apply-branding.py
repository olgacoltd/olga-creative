#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Data-level branding for the GIMP-based app (the source patches in ./patches do the code side).

usage:
  python apply-branding.py source <gimp source dir> <brand.json>
      run AFTER the patches, on a pristine tree (the build script resets it first):
        1. defaults   Photoshop-style shortcuts / layout / toolbox / tool options -> etc/ (see defaults/README.md)
        2. strings    zh_TW catalogs of every GIMP text domain: "GIMP" -> brand; po/en.po generated so English
                      systems see the brand too. Credits, licence, links, version history, file-format names
                      keep "GIMP".
        3. artwork    logo SVGs (About logo, app/file icons, installer icons are generated from them during the
                      build) and the committed .ico files used by the exe resources
  python apply-branding.py bundle <bundle dir> <brand.json> <meson build dir>
      run on the finished bundle: splash screen, and the installer's splash/banner bitmaps that upstream
      renders from its own splash artwork during the build.
Needs Pillow. Fonts come from brand.json (Windows font paths).
"""
import base64
import io
import json
import os
import re
import shutil
import sys

from PIL import Image, ImageDraw, ImageFont

MODE, TARGET, BRAND_FILE = sys.argv[1], sys.argv[2], sys.argv[3]
B = json.load(open(BRAND_FILE, encoding='utf-8'))
G = B['gimp']
NAME = G['name']
COL = B['colors']
HERE = os.path.dirname(os.path.abspath(__file__))


def p(*parts):
    return os.path.join(TARGET, *parts)


def write_text(path, text):
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)


# ---------------------------------------------------------------------------------------
# 1. defaults (Photoshop-like): shipped as the app's system-wide defaults, never into a user profile
# ---------------------------------------------------------------------------------------
def brand_defaults():
    d = os.path.join(HERE, 'defaults')
    for fn in ('shortcutsrc', 'sessionrc', 'toolrc'):
        shutil.copyfile(os.path.join(d, fn), p('etc', fn))
    with open(p('etc', 'gimprc.in'), 'a', encoding='utf-8', newline='\n') as f:
        f.write(open(os.path.join(d, 'gimprc'), encoding='utf-8').read())
    # product templates first in File > New, GIMP's own templates kept after them
    tpl = p('etc', 'templaterc')
    upstream = open(tpl, encoding='utf-8').read()
    first = upstream.index('(GimpTemplate ')
    extra = open(os.path.join(d, 'templaterc-extra'), encoding='utf-8').read()
    write_text(tpl, upstream[:first] + extra.rstrip('\n') + '\n\n# GIMP templates\n\n' + upstream[first:])
    dest = p('etc', 'defaults')
    os.makedirs(dest, exist_ok=True)
    n = 0
    for root, _dirs, files in os.walk(os.path.join(d, 'profile')):
        rel = os.path.relpath(root, os.path.join(d, 'profile'))
        os.makedirs(os.path.join(dest, rel), exist_ok=True)
        for fn in files:
            shutil.copyfile(os.path.join(root, fn), os.path.join(dest, rel, fn))
            n += 1
    print('defaults: shortcutsrc, sessionrc, toolrc, gimprc additions, templates, %d profile files' % n)


# ---------------------------------------------------------------------------------------
# 2. translations
# ---------------------------------------------------------------------------------------
# Strings that keep saying "GIMP": credits, licence, links, upstream help/docs, version history,
# file-format and resource-format names (other programs know them by these names), identifiers.
PROTECT = re.compile(
    r'GIMP (Development Team|[Tt]eam|[Dd]evelopers|[Pp]roject|[Ww]ebsite|[Oo]nline|[Hh]elp|[Mm]anual|'
    r'[Dd]ocumentation|[Ww]iki|[Cc]ontributors|[Ff]oundation|XCF|[Bb]rush|[Pp]attern|[Pp]alette|[Gg]radient|'
    r'[Cc]urves|[Ll]evels|[Ii]mage [Ff]ile|[Tt]ool [Pp]reset|[Dd]ynamics|[Bb]rush [Pp]ipe|[Ff]ile [Ff]ormat|[Uu]ser [Mm]anual)'
    r'|gimp\.org|GIMP \d|GIMP is free software|along with GIMP|GIMP is distributed|Spencer Kimball|Peter Mattis'
    r'|XCF|libgimp|GIMP[-_]|_GIMP|gimprc|PhotoGIMP|Wilber|GEGL|babl')
PROTECT_ZH = re.compile(r'GIMP\s*(開發|團隊|社群|網站|線上|說明|手冊|文件|專案|筆刷|圖樣|色票|漸層|曲線|色階|基金)|gimp\.org|XCF')
WORD = re.compile(r'(?<![A-Za-z_])GIMP(?![A-Za-z_\-])')


def parse_po(text):
    entries, cur = [], []
    for line in text.split('\n'):
        if line.strip() == '':
            if cur:
                entries.append(cur)
                cur = []
            continue
        cur.append(line)
    if cur:
        entries.append(cur)
    return entries


def unq(s):
    s = s.strip()
    assert s.startswith('"') and s.endswith('"'), s
    return s[1:-1]


def fields(entry):
    out, kind = {}, None
    for line in entry:
        if line.startswith('#'):
            kind = None
            continue
        m = re.match(r'^(msgctxt|msgid_plural|msgid|msgstr(?:\[\d+\])?)\s+(".*")\s*$', line)
        if m:
            kind = m.group(1)
            out[kind] = unq(m.group(2))
        elif line.startswith('"') and kind:
            out[kind] += unq(line)
    return out


def brand_text(s):
    return WORD.sub(NAME, s)


def rebrand_po(path):
    text = open(path, encoding='utf-8').read()
    entries = parse_po(text)
    changed = 0
    out = []
    for e in entries:
        f = fields(e)
        mid = f.get('msgid', '') + ' ' + f.get('msgid_plural', '')
        strs = ' '.join(v for k, v in f.items() if k.startswith('msgstr'))
        if f.get('msgid') and not PROTECT.search(mid) and not PROTECT.search(strs) and not PROTECT_ZH.search(strs):
            new, kind, hit = [], None, False
            for line in e:
                m = re.match(r'^(msgctxt|msgid_plural|msgid|msgstr(?:\[\d+\])?)\s', line)
                if m:
                    kind = m.group(1)
                elif line.startswith('#'):
                    kind = None
                if kind and kind.startswith('msgstr') and WORD.search(line):
                    line = brand_text(line)
                    hit = True
                new.append(line)
            if hit:
                changed += 1
            e = new
        out.append('\n'.join(e))
    with open(path, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write('\n\n'.join(out) + '\n')
    return changed


def po_quote(s):
    return '"' + s + '"'   # s is already in escaped (PO) form


def make_en_po(source_po, dest):
    """English catalog with only the entries that mention GIMP (msgids taken from an existing catalog)."""
    entries = parse_po(open(source_po, encoding='utf-8').read())
    lines = ['msgid ""', 'msgstr ""',
             '"Content-Type: text/plain; charset=UTF-8\\n"',
             '"Content-Transfer-Encoding: 8bit\\n"',
             '"Language: en\\n"',
             '"Plural-Forms: nplurals=2; plural=(n != 1);\\n"', '']
    n = 0
    for e in entries:
        f = fields(e)
        mid = f.get('msgid', '')
        both = mid + ' ' + f.get('msgid_plural', '')
        if not mid or not WORD.search(both) or PROTECT.search(both):
            continue
        if any(l.startswith('#~') for l in e):      # obsolete entries
            continue
        flags = [re.sub(r',?\s*fuzzy', '', l) for l in e if l.startswith('#,')]
        lines += [l for l in flags if l.strip() != '#,']
        if 'msgctxt' in f:
            lines.append('msgctxt ' + po_quote(f['msgctxt']))
        lines.append('msgid ' + po_quote(mid))
        if 'msgid_plural' in f:
            lines.append('msgid_plural ' + po_quote(f['msgid_plural']))
            lines.append('msgstr[0] ' + po_quote(brand_text(mid)))
            lines.append('msgstr[1] ' + po_quote(brand_text(f['msgid_plural'])))
        else:
            lines.append('msgstr ' + po_quote(brand_text(mid)))
        lines.append('')
        n += 1
    write_text(dest, '\n'.join(lines) + '\n')
    return n


def brand_translations():
    total = 0
    for d in sorted(os.listdir(TARGET)):
        zh = p(d, 'zh_TW.po')
        if d.startswith('po') and os.path.isfile(zh):
            n = rebrand_po(zh)
            total += n
            print('strings: %s/zh_TW.po %d entries rebranded' % (d, n))
    # English: GIMP's main text domain only (menus, dialogs, messages)
    n = make_en_po(p('po', 'zh_TW.po'), p('po', 'en.po'))
    linguas = p('po', 'LINGUAS')
    langs = open(linguas, encoding='utf-8').read().split('\n')
    if 'en' not in [l.strip() for l in langs]:
        write_text(linguas, '\n'.join(l for l in langs if l.strip()) + '\nen\n')
    # the Windows installer lists one component per po/*.po and fails the build for a language it does not know
    iso = p('build', 'windows', 'installer', 'lang', 'iso_639_custom.xml')
    if os.path.isfile(iso):
        xml = open(iso, encoding='utf-8').read()
        if 'dl_code="en"' not in xml:
            entry = ('\t<iso_639_entry\n\t\tdl_code="en"\n\t\tinno_code="Default.isl"\n'
                     '\t\tname="English" />\n')
            write_text(iso, xml.replace('</iso_639_entries>', entry + '</iso_639_entries>'))
    print('strings: po/en.po generated with %d branded entries (zh_TW total %d)' % (n, total))


# ---------------------------------------------------------------------------------------
# 3. artwork
# ---------------------------------------------------------------------------------------
def hex2rgb(h):
    h = h.lstrip('#')
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


PRIMARY, ACCENT, TEXT = hex2rgb(COL['primary']), hex2rgb(COL['accent']), hex2rgb(COL['text'])


def font_for(text, size):
    cands = B['font']['cjk'] if any(ord(c) > 0x2E7F for c in text) else B['font']['latin'] + B['font']['cjk']
    for f in cands:
        if os.path.exists(f):
            return ImageFont.truetype(f, size)
    return ImageFont.load_default()


def draw_centered(d, xy_box, text, size, fill):
    x0, y0, x1, y1 = xy_box
    ft = font_for(text, size)
    bb = d.textbbox((0, 0), text, font=ft)
    w, h = bb[2] - bb[0], bb[3] - bb[1]
    d.text((x0 + (x1 - x0 - w) / 2 - bb[0], y0 + (y1 - y0 - h) / 2 - bb[1]), text, font=ft, fill=fill)


def icon_image(size, page=False):
    s = size * 4                               # supersample
    im = Image.new('RGBA', (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    if page:
        # document icon (file types): white page with a folded corner, small brand tile on it
        fold = s * 0.26
        d.polygon([(s * 0.14, 0), (s * 0.86 - fold, 0), (s * 0.86, fold), (s * 0.86, s - 1), (s * 0.14, s - 1)],
                  fill=(250, 250, 250, 255), outline=(150, 150, 150, 255))
        d.polygon([(s * 0.86 - fold, 0), (s * 0.86 - fold, fold), (s * 0.86, fold)], fill=(210, 210, 210, 255))
        t0, t1 = s * 0.24, s * 0.76
        d.rounded_rectangle((t0, s * 0.36, t1, s * 0.36 + (t1 - t0)), radius=s // 14, fill=PRIMARY + (255,))
        draw_centered(d, (t0, s * 0.36, t1, s * 0.36 + (t1 - t0) * 0.9), G['monogram'], int(s * 0.34), TEXT + (255,))
    else:
        r = s // 5
        d.rounded_rectangle((0, 0, s - 1, s - 1), radius=r, fill=PRIMARY + (255,))
        d.rounded_rectangle((s * 0.08, s * 0.72, s * 0.92, s * 0.80), radius=s // 40, fill=ACCENT + (255,))
        draw_centered(d, (0, 0, s, s * 0.80), G['monogram'], int(s * 0.58), TEXT + (255,))
    return im.resize((size, size), Image.LANCZOS)


def svg_wrapping_png(im, size):
    """An SVG that only embeds a PNG: the build renders these SVGs with librsvg (no font dependency)."""
    buf = io.BytesIO()
    im.save(buf, 'PNG')
    data = base64.b64encode(buf.getvalue()).decode('ascii')
    return ('<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
            'width="{s}" height="{s}" viewBox="0 0 {s} {s}">'
            '<image width="{s}" height="{s}" xlink:href="data:image/png;base64,{d}" href="data:image/png;base64,{d}"/>'
            '</svg>\n').format(s=size, d=data)


def symbolic_svg():
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">'
            '<rect x="1" y="1" width="14" height="14" rx="3" fill="none" stroke="#bebebe" stroke-width="2"/>'
            '<rect x="4" y="11" width="8" height="1.5" fill="#bebebe"/></svg>\n')


def brand_artwork():
    logo = p('gimp-data', 'images', 'logo')
    big = icon_image(512)
    for fn in ('gimp-logo.svg', 'gimp-logo-shadow.svg', 'gimp-devel-logo.svg', 'gimp-logo-unicolor.svg',
               'gimp-logo-outline.svg', 'gimp-logo-macos.svg'):
        if os.path.exists(os.path.join(logo, fn)):
            write_text(os.path.join(logo, fn), svg_wrapping_png(big, 512))
    if os.path.exists(os.path.join(logo, 'gimp-wilber-symbolic.svg')):
        write_text(os.path.join(logo, 'gimp-wilber-symbolic.svg'), symbolic_svg())
    sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
    icon_image(256).save(os.path.join(logo, 'gimp.ico'), sizes=[(s, s) for s in sizes])
    icon_image(256).save(os.path.join(logo, 'plug-ins.ico'), sizes=[(s, s) for s in sizes])
    for fn in ('fileicon.ico', 'fileicon-xcf.ico'):
        icon_image(256, page=True).save(os.path.join(logo, fn), sizes=[(s, s) for s in sizes])
    print('artwork: logo SVGs (About logo, app/file/installer icons are rendered from them), gimp/plug-ins/file .ico')


def banner(w, h, credit=True, mode='RGB'):
    im = Image.new('RGB', (w, h), PRIMARY)
    d = ImageDraw.Draw(im)
    d.rectangle((0, h - max(3, h // 40), w, h), fill=ACCENT)
    tag = G.get('tagline_zh_TW') or G.get('tagline') or ''
    if h >= 160 and w >= 2 * h // 3:
        draw_centered(d, (0, h * 0.14, w, h * 0.56), NAME, int(min(h * 0.26, w * 0.16)), TEXT)
        if tag:
            draw_centered(d, (0, h * 0.58, w, h * 0.74), tag, int(min(h * 0.08, w * 0.06)), ACCENT)
        if credit:
            draw_centered(d, (0, h * 0.78, w, h * 0.92), 'Based on GIMP (GPL)', max(10, int(min(h * 0.045, w * 0.035))), (200, 208, 220))
    elif h >= 48:
        draw_centered(d, (0, 0, w, h * 0.9), NAME, int(min(h * 0.4, w * 0.14)), TEXT)
    return im.convert(mode)


def brand_bundle():
    bundle, build = TARGET, sys.argv[4]
    n = 0
    for root, _dirs, files in os.walk(os.path.join(bundle, 'share', 'gimp')):
        for fn in files:
            if fn == 'gimp-splash.png':
                f = os.path.join(root, fn)
                w, h = Image.open(f).size
                banner(w, h).save(f)
                n += 1
    print('bundle: %d splash image(s) replaced' % n)
    inst = os.path.join(build, 'build', 'windows', 'installer')
    n = 0
    if os.path.isdir(inst):
        for fn in os.listdir(inst):
            if fn.endswith('.bmp') and (fn.startswith('installsplash') or fn.startswith('install-end')):
                f = os.path.join(inst, fn)
                src = Image.open(f)
                w, h = src.size
                mode = 'RGBA' if src.mode == 'RGBA' else 'RGB'
                banner(w, h, credit=h >= 200, mode=mode).save(f)
                n += 1
    print('bundle: %d installer splash/banner bitmaps replaced' % n)


if __name__ == '__main__':
    if MODE == 'source':
        brand_defaults()
        brand_translations()
        brand_artwork()
    elif MODE == 'bundle':
        brand_bundle()
    else:
        sys.exit('mode must be "source" or "bundle"')
    print('branding (%s) applied: %s' % (MODE, NAME))
