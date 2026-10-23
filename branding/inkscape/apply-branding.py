#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Data-level branding for an Inkscape source tree (run AFTER the patches in ./patches).

usage: python apply-branding.py <inkscape source dir> <brand.json>

Expects a pristine tree (the build script resets the checkout first). Does:
  1. keymap   share/keys/brand-default.xml from the configured preset (prefs default points at it)
  2. strings  po/zh_TW.po: msgstr "Inkscape" -> brand; po/en.po generated from inkscape.pot so English
              systems also see the brand. Credits/licence/version-history strings keep "Inkscape".
  3. artwork  app icon (.ico + hicolor PNG/SVG), splash/welcome banners, About screen, installer bitmaps
Needs Pillow. Fonts come from brand.json (Windows font paths).
"""
import gzip
import json
import os
import re
import sys

from PIL import Image, ImageDraw, ImageFont

SRC, BRAND_FILE = sys.argv[1], sys.argv[2]
B = json.load(open(BRAND_FILE, encoding='utf-8'))
INK = B['inkscape']
NAME = INK['name']
COL = B['colors']


def p(*parts):
    return os.path.join(SRC, *parts)


# ---------------------------------------------------------------------------------------
# 1. keymap
# ---------------------------------------------------------------------------------------
def brand_keymap():
    src = p('share', 'keys', INK['keymapSource'])
    xml = open(src, encoding='utf-8').read()
    xml = re.sub(r'<keys name="[^"]*"', '<keys name="%s"' % INK['keymapName'], xml, count=1)
    # drop the descriptive comment that names the third-party product
    xml = re.sub(r'<!--\s*\nThis file contains a profile.*?-->\n', '', xml, count=1, flags=re.S)
    with open(p('share', 'keys', 'brand-default.xml'), 'w', encoding='utf-8', newline='\n') as f:
        f.write(xml)
    removed = []
    if INK.get('dropThirdPartyBrandedFiles'):
        for fn in os.listdir(p('share', 'keys')):
            if fn.startswith('adobe-'):
                os.remove(p('share', 'keys', fn))
                removed.append(fn)
    print('keymap: brand-default.xml <- %s (name "%s"); removed %s' % (INK['keymapSource'], INK['keymapName'], removed or 'nothing'))


# ---------------------------------------------------------------------------------------
# 2. translations
# ---------------------------------------------------------------------------------------
# Strings that must keep saying "Inkscape": credits, licence, links, upstream version history,
# and the "Inkscape SVG" file-format name (other tools recognise it).
PROTECT = re.compile(
    r'Inkscape (Developers|developers|[Pp]roject|Board|[Cc]ommunity|[Ww]ebsite|licen[cs]es?|[Cc]ontributors|team|Team|SVG)'
    r'|inkscape\.org|contribute|get involved|Inkscape \d|Inkscape-\d|\d\.\d+ Inkscape|INKSCAPE')


def parse_po(text):
    """Return a list of entries; each entry is a list of (kind, value_lines, raw_lines)."""
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
    """dict kind -> joined string (escaped form) for msgctxt/msgid/msgid_plural/msgstr/msgstr[n]."""
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
    return s.replace('Inkscape', NAME)


def rebrand_po(path):
    text = open(path, encoding='utf-8').read()
    entries = parse_po(text)
    changed = 0
    out = []
    for e in entries:
        f = fields(e)
        mid = f.get('msgid', '') + ' ' + f.get('msgid_plural', '')
        if f.get('msgid') and not PROTECT.search(mid) and not PROTECT.search(' '.join(v for k, v in f.items() if k.startswith('msgstr'))):
            new, kind, hit = [], None, False
            for line in e:
                m = re.match(r'^(msgctxt|msgid_plural|msgid|msgstr(?:\[\d+\])?)\s', line)
                if m:
                    kind = m.group(1)
                elif line.startswith('#'):
                    kind = None
                if kind and kind.startswith('msgstr') and 'Inkscape' in line:
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


def make_en_po(pot, dest):
    entries = parse_po(open(pot, encoding='utf-8').read())
    lines = ['msgid ""', 'msgstr ""',
             '"Content-Type: text/plain; charset=UTF-8\\n"',
             '"Content-Transfer-Encoding: 8bit\\n"',
             '"Language: en\\n"',
             '"Plural-Forms: nplurals=2; plural=(n != 1);\\n"', '']
    n = 0
    for e in entries:
        f = fields(e)
        mid = f.get('msgid', '')
        if not mid or 'Inkscape' not in (mid + f.get('msgid_plural', '')):
            continue
        if PROTECT.search(mid + ' ' + f.get('msgid_plural', '')):
            continue
        flags = [l for l in e if l.startswith('#,')]
        lines += flags
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
    # drop "fuzzy" flags so msgfmt compiles every entry
    lines = [re.sub(r',?\s*fuzzy', '', l) if l.startswith('#,') else l for l in lines]
    lines = [l for l in lines if l.strip() != '#,']
    with open(dest, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write('\n'.join(lines) + '\n')
    return n


def brand_translations():
    zh = p('po', 'zh_TW.po')
    print('strings: zh_TW.po %d entries rebranded' % rebrand_po(zh))
    n = make_en_po(p('po', 'inkscape.pot'), p('po', 'en.po'))
    print('strings: en.po generated with %d branded entries' % n)


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


def icon_image(size):
    s = size * 4                               # supersample
    im = Image.new('RGBA', (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    r = s // 5
    d.rounded_rectangle((0, 0, s - 1, s - 1), radius=r, fill=PRIMARY + (255,))
    d.rounded_rectangle((s * 0.08, s * 0.72, s * 0.92, s * 0.80), radius=s // 40, fill=ACCENT + (255,))
    draw_centered(d, (0, 0, s, s * 0.80), INK['monogram'], int(s * 0.58), TEXT + (255,))
    return im.resize((size, size), Image.LANCZOS)


def svg_icon(symbolic=False):
    if symbolic:
        return ('<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">'
                '<rect x="1" y="1" width="14" height="14" rx="3" fill="none" stroke="#bebebe" stroke-width="2"/>'
                '<rect x="4" y="11" width="8" height="1.5" fill="#bebebe"/></svg>\n')
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128">'
            '<rect width="128" height="128" rx="26" fill="%s"/>'
            '<rect x="10" y="92" width="108" height="10" rx="3" fill="%s"/>'
            '<text x="64" y="80" font-family="Segoe UI, Microsoft JhengHei, sans-serif" font-weight="700" '
            'font-size="74" fill="%s" text-anchor="middle">%s</text></svg>\n'
            % (COL['primary'], COL['accent'], COL['text'], INK['monogram']))


def banner(w, h, title, subtitle=None, credit=True, mode='RGBA'):
    im = Image.new('RGB', (w, h), PRIMARY)
    d = ImageDraw.Draw(im)
    d.rectangle((0, h - max(3, h // 40), w, h), fill=ACCENT)
    if h >= 120:
        draw_centered(d, (0, h * 0.12, w, h * 0.58), title, int(h * 0.30), TEXT)
        if subtitle:
            draw_centered(d, (0, h * 0.58, w, h * 0.76), subtitle, int(h * 0.09), ACCENT)
        if credit:
            draw_centered(d, (0, h * 0.78, w, h * 0.94), 'Based on Inkscape (GPL)', max(10, int(h * 0.055)), (200, 208, 220))
    else:
        draw_centered(d, (0, 0, w, h * 0.9), title, int(h * 0.45), TEXT)
    return im.convert(mode)


def brand_artwork():
    # Windows icon (exe resource, installer)
    ico = p('share', 'branding', 'inkscape.ico')
    sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
    icon_image(256).save(ico, sizes=[(s, s) for s in sizes])
    # in-app window/taskbar icon: GTK looks up the icon *name* org.inkscape.Inkscape (kept), we swap the pixels
    appdir = p('share', 'icons', 'application')
    for sz in (16, 22, 24, 32, 48, 256):
        icon_image(sz).save(os.path.join(appdir, '%dx%d' % (sz, sz), 'org.inkscape.Inkscape.png'))
    open(os.path.join(appdir, 'scalable', 'org.inkscape.Inkscape.svg'), 'w', newline='\n').write(svg_icon())
    open(os.path.join(appdir, 'symbolic', 'org.inkscape.Inkscape-symbolic.svg'), 'w', newline='\n').write(svg_icon(True))
    # logo SVGs installed under share/branding (used by docs/templates); keep file names
    for fn in ('inkscape.svg', 'inkscape-flat.svg'):
        open(p('share', 'branding', fn), 'w', newline='\n').write(svg_icon())
    print('artwork: icon (.ico %s, hicolor PNG/SVG)' % sizes)

    # splash + welcome banners (700x220 in 1.4)
    scr = p('share', 'screens')
    tag = INK.get('tagline_zh_TW') or INK.get('tagline')
    for fn, sub in (('start-splash.png', tag), ('start-welcome.png', tag), ('start-support.png', INK.get('tagline'))):
        w, h = Image.open(os.path.join(scr, fn)).size
        banner(w, h, NAME, sub).save(os.path.join(scr, fn))
    print('artwork: splash/welcome banners')

    # About screen: one SVGZ with the brand and the upstream credit
    about = os.path.join(scr, 'about')
    for fn in os.listdir(about):
        if fn.endswith('.svgz') or fn.endswith('.svg'):
            os.remove(os.path.join(about, fn))
    svg = ('<svg xmlns="http://www.w3.org/2000/svg" width="750" height="625" viewBox="0 0 750 625">'
           '<rect width="750" height="625" fill="{p}"/><rect y="600" width="750" height="25" fill="{a}"/>'
           '<rect x="315" y="120" width="120" height="120" rx="24" fill="{a}"/>'
           '<text x="375" y="212" font-family="Segoe UI, Microsoft JhengHei, sans-serif" font-size="80" font-weight="700" fill="{p}" text-anchor="middle">{m}</text>'
           '<text x="375" y="350" font-family="Segoe UI, Microsoft JhengHei, sans-serif" font-size="72" font-weight="700" fill="{t}" text-anchor="middle">{n}</text>'
           '<text x="375" y="405" font-family="Microsoft JhengHei, Segoe UI, sans-serif" font-size="26" fill="{a}" text-anchor="middle">{tag}</text>'
           '<text x="375" y="520" font-family="Segoe UI, sans-serif" font-size="20" fill="#c8d0dc" text-anchor="middle">Based on Inkscape (GPL) - https://inkscape.org</text>'
           '<text x="375" y="550" font-family="Segoe UI, sans-serif" font-size="16" fill="#c8d0dc" text-anchor="middle">Inkscape is (C) the Inkscape developers, licensed under the GNU GPL</text>'
           '</svg>\n').format(p=COL['primary'], a=COL['accent'], t=COL['text'], m=INK['monogram'], n=NAME, tag=tag)
    with gzip.open(os.path.join(about, 'about00.svgz'), 'wb') as f:
        f.write(svg.encode('utf-8'))
    print('artwork: about screen')

    # installer bitmaps (24-bit BMP, same sizes as upstream)
    for rel in (('packaging', 'nsis', 'header.bmp'), ('packaging', 'nsis', 'welcomefinish.bmp'),
                ('packaging', 'wix', 'Bitmaps', 'banner.bmp'), ('packaging', 'wix', 'Bitmaps', 'dialog.bmp')):
        f = p(*rel)
        if os.path.exists(f):
            w, h = Image.open(f).size
            banner(w, h, NAME, INK.get('tagline'), credit=h >= 200, mode='RGB').save(f)
    print('artwork: installer bitmaps')


# ---------------------------------------------------------------------------------------
# 4. helper scripts shipped in the package
# ---------------------------------------------------------------------------------------
def brand_scripts():
    bt = p('packaging', 'win32', 'gdb_create_backtrace.bat')
    s = open(bt, encoding='utf-8').read()
    s = (s.replace('inkscape.com', INK['id'] + '.com').replace('inkscape.exe', INK['id'] + '.exe')
          .replace('inkscape_backtrace.txt', INK['id'] + '_backtrace.txt')
          .replace('INKSCAPE VERSION', NAME.upper() + ' VERSION').replace('Inkscape', NAME))
    s = '\n'.join(l for l in s.split('\n') if 'inkscape.org/report' not in l)
    open(bt, 'w', encoding='utf-8', newline='\r\n').write(s.replace('\r\n', '\n'))
    dbg = p('packaging', 'win32', 'Run Inkscape and create debug trace.bat')
    # unchanged content (it only starts gdb_create_backtrace.bat); installed under a branded name by patch 0007
    print('scripts: gdb_create_backtrace.bat branded (%s)' % ('ok' if os.path.exists(dbg) else 'launcher missing'))


if __name__ == '__main__':
    brand_keymap()
    brand_translations()
    brand_artwork()
    brand_scripts()
    print('branding applied: %s' % NAME)
