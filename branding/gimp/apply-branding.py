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
        2b. terms     zh_TW wording Photoshop users know, from zh_TW-terms.csv (validated, msgfmt --check),
                      plus a review sheet po/olga-zh_TW-terms-review.md
        3. artwork    logo SVGs (About logo, app/file icons, installer icons are generated from them during the
                      build) and the committed .ico files used by the exe resources
        4. mascot     every upstream mascot picture (icon themes, error icon, splash easter egg, brush)
                      replaced by the product artwork (the empty-canvas drawing is source patch 0007)
  python apply-branding.py bundle <bundle dir> <brand.json> <meson build dir>
      run on the finished bundle: splash screen, and the installer's splash/banner bitmaps that upstream
      renders from its own splash artwork during the build.
Needs Pillow. Fonts come from brand.json (Windows font paths).
"""
import base64
import csv
import io
import json
import os
import re
import shutil
import subprocess
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
# 2b. zh_TW wording: the terms Photoshop users in Taiwan know, from the reviewable table zh_TW-terms.csv
# ---------------------------------------------------------------------------------------
TERMS_FILE = os.path.join(HERE, 'zh_TW-terms.csv')
FMT = re.compile(r'%(?:\d+\$)?[-+ #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|L|q|j|z|t|I64|I32)?[diouxXeEfFgGaAcspn%]')
TERMS_SHEET = 'olga-zh_TW-terms-review.md'


def po_unescape(s):
    out, i = [], 0
    while i < len(s):
        if s[i] == '\\' and i + 1 < len(s):
            out.append({'n': '\n', 't': '\t', '"': '"', '\\': '\\'}.get(s[i + 1], '\\' + s[i + 1]))
            i += 2
        else:
            out.append(s[i])
            i += 1
    return ''.join(out)


def po_escape(s):
    return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\t', '\\t')


def n_mnemonics(s):
    return len(re.findall(r'_(?=[^_\s])', s.replace('__', '')))


def set_msgstr(entry, value, plural=False):
    """entry lines with the msgstr replaced by value and the fuzzy flag dropped (msgfmt skips fuzzy entries);
    a plural entry gets one form, msgstr[0] (Chinese has a single plural form)"""
    out, in_str, done = [], False, False
    for line in entry:
        if line.startswith('#,'):
            flags = [f.strip() for f in line[2:].split(',') if f.strip() and f.strip() != 'fuzzy']
            if flags:
                out.append('#, ' + ', '.join(flags))
            continue
        if line.startswith('msgstr'):
            if not done:
                out.append('%s "%s"' % ('msgstr[0]' if plural else 'msgstr', po_escape(value)))
                done = True
            in_str = True
            continue
        if in_str and line.startswith('"'):
            continue
        in_str = False
        out.append(line)
    return out


def brand_terms():
    rows = list(csv.DictReader(open(TERMS_FILE, encoding='utf-8-sig', newline='')))
    path = p('po', 'zh_TW.po')
    entries = parse_po(open(path, encoding='utf-8').read())
    index = {}
    for i, e in enumerate(entries):
        f = fields(e)
        if f.get('msgid'):
            index[(po_unescape(f.get('msgctxt', '')), po_unescape(f['msgid']))] = i
    errors, status = [], []
    for n, r in enumerate(rows, start=2):
        ctx, mid = r['context'].strip(), r['msgid']
        cur, new = r['current_zh_TW'], r['new_zh_TW'].strip()
        where = 'zh_TW-terms.csv line %d (%s)' % (n, mid)
        if not new:
            errors.append(where + ': new_zh_TW is empty')
            continue
        if n_mnemonics(new) != min(n_mnemonics(mid), 1):
            errors.append(where + ': the new text must carry %s menu mnemonic like (_X)'
                          % ('one' if n_mnemonics(mid) else 'no'))
        if sorted(FMT.findall(mid)) != sorted(FMT.findall(new)):
            errors.append(where + ': format specifiers differ from the English text (%s)' % ' '.join(FMT.findall(mid)))
        key = (ctx, mid)
        if key in index:
            e = entries[index[key]]
            f = fields(e)
            plural = 'msgid_plural' in f
            if plural and not re.search(r'nplurals\s*=\s*1\b', '\n'.join(entries[0])):
                errors.append(where + ': plural entry in a catalog with more than one plural form')
                continue
            have = po_unescape(f.get('msgstr[0]' if plural else 'msgstr', ''))
            if have != cur:
                errors.append(where + ': the catalog now says %r, the table expects %r (upstream changed it: review the row)'
                              % (have, cur))
                continue
            entries[index[key]] = set_msgstr(e, new, plural)
            status.append('changed')
        elif cur:
            errors.append(where + ': not in the catalog (upstream renamed or dropped this text)')
        else:
            add = ['#. olga-creative: added (%s)' % r['term']]
            if ctx:
                add.append('msgctxt "%s"' % po_escape(ctx))
            add += ['msgid "%s"' % po_escape(mid), 'msgstr "%s"' % po_escape(new)]
            entries.append(add)
            index[key] = len(entries) - 1
            status.append('added')
    if errors:
        sys.exit('zh_TW terms:\n  ' + '\n  '.join(errors))
    with open(path, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write('\n\n'.join('\n'.join(e) for e in entries) + '\n')
    # the catalog must still compile cleanly (mnemonics, format strings, headers)
    msgfmt = shutil.which('msgfmt')
    if msgfmt:
        mo = p('po', '.olga-check.mo')
        res = subprocess.run([msgfmt, '--check', '-o', mo, path], capture_output=True, text=True)
        if os.path.exists(mo):
            os.remove(mo)
        if res.returncode != 0:
            sys.exit('zh_TW terms: msgfmt --check failed:\n' + res.stderr)
        print('terms: msgfmt --check po/zh_TW.po: clean')
    else:
        print('terms: msgfmt not found, catalog not checked here (the smoke test checks it)')
    # review sheet for staff (the build copies it next to the packages)
    def cell(s):
        return (s or '').replace('|', '\\|').replace('\n', ' ')
    lines = ['# %s zh_TW 用語對照(候選版,請在介面上確認)' % NAME, '',
             '來源:`branding/gimp/zh_TW-terms.csv`。要改就改那個表,再重新建置。',
             '「目前譯文」是上游 GIMP 的繁中翻譯;「新譯文」是本版實際使用的文字。', '',
             'Source table: `branding/gimp/zh_TW-terms.csv` (edit it and rebuild). %d entries, %d terms.'
             % (len(rows), len(set(r['term'] for r in rows))), '',
             '| 用語 Term | 位置 Context | English | 目前譯文 Current | 新譯文 New | 理由 Why | 狀態 |',
             '|---|---|---|---|---|---|---|']
    for r, st in zip(rows, status):
        lines.append('| %s | %s | %s | %s | %s | %s | %s |' % (
            cell(r['term']), cell(r['context']) or '-', cell(r['msgid']), cell(r['current_zh_TW']) or '(無,新增)',
            cell(r['new_zh_TW']), cell(r['why']), '已改' if st == 'changed' else '新增'))
    write_text(p('po', TERMS_SHEET), '\n'.join(lines) + '\n')
    print('terms: %d zh_TW entries changed, %d added (%d terms); review sheet po/%s'
          % (status.count('changed'), status.count('added'), len(set(r['term'] for r in rows)), TERMS_SHEET))


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


def icon_image(size, page=False, glyph=None):
    """The product icon: brand-colour tile, accent bar, monogram (or another glyph, e.g. '!' for alerts)."""
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
        draw_centered(d, (0, 0, s, s * 0.80), glyph or G['monogram'], int(s * 0.58), TEXT + (255,))
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


def symbolic_svg(alert=False):
    mark = ('<rect x="7" y="3.5" width="2" height="5.5" fill="#bebebe"/><rect x="7" y="10" width="2" height="2" fill="#bebebe"/>'
            if alert else '<rect x="4" y="11" width="8" height="1.5" fill="#bebebe"/>')
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">'
            '<rect x="1" y="1" width="14" height="14" rx="3" fill="none" stroke="#bebebe" stroke-width="2"/>'
            + mark + '</svg>\n')


def brand_mascot():
    """Replace every upstream mascot picture a customer can see (icon themes, error/"image missing" icon,
    the splash easter egg, the mascot brush) with the product's own artwork. Every file touched is listed
    in the build log."""
    replaced = []

    def put(rel, data):
        f = p(*rel.split('/'))
        if not os.path.exists(f):
            sys.exit('mascot: expected upstream file is missing: ' + rel)
        if isinstance(data, Image.Image):
            data.save(f, 'PNG')
        else:
            write_text(f, data)
        replaced.append(rel)

    icons = 'gimp-data/icons'
    # Default theme: the colour and symbolic "eek" (error dialogs; also installed as image-missing)
    put(icons + '/Default/scalable/gimp-wilber-eek.svg', svg_wrapping_png(icon_image(256, glyph='!'), 256))
    put(icons + '/Default/scalable/gimp-wilber-eek-symbolic.svg', symbolic_svg(alert=True))
    # Legacy theme (selectable in Preferences): the mascot at every size, its "eek" and its SVG
    for sz in (16, 22, 32, 48, 64, 96, 128, 192, 256):
        put('%s/Legacy/%d/gimp-wilber.png' % (icons, sz), icon_image(sz))
    put(icons + '/Legacy/64/gimp-wilber-eek.png', icon_image(64, glyph='!'))
    put(icons + '/Legacy/scalable/gimp-wilber.svg', svg_wrapping_png(icon_image(256), 256))
    # (the build installs images/logo/gimp-wilber-symbolic.svg in its place, see brand_artwork; keep both equal)
    put(icons + '/Default/scalable/gimp-wilber-symbolic.svg', symbolic_svg())
    # splash easter egg (a PNG despite the name)
    put('gimp-data/images/sidrat.data', icon_image(250))
    # the mascot brush (Brushes dock, "Fun" tag): not shipped
    fun = p('gimp-data', 'brushes', 'Fun', 'meson.build')
    text = open(fun, encoding='utf-8').read()
    if "'Wilber.gih'," not in text:
        sys.exit('mascot: gimp-data/brushes/Fun/meson.build no longer lists Wilber.gih')
    write_text(fun, text.replace("  'Wilber.gih',\n", ''))
    os.remove(p('gimp-data', 'brushes', 'Fun', 'Wilber.gih'))
    replaced.append('gimp-data/brushes/Fun/Wilber.gih (removed)')
    for r in replaced:
        print('mascot: ' + r)
    print('mascot: %d files replaced or removed; the empty-canvas drawing is patch 0007' % len(replaced))


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
        brand_terms()
        brand_artwork()
        brand_mascot()
    elif MODE == 'bundle':
        brand_bundle()
    else:
        sys.exit('mode must be "source" or "bundle"')
    print('branding (%s) applied: %s' % (MODE, NAME))
