#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Traditional Chinese for the bundled Resynthesizer plug-ins, through their own gettext catalog.

Resynthesizer's plug-ins are already internationalised upstream: every outer plug-in (a Script-Fu script run
by the stand-alone interpreter) declares  (script-fu-register-i18n "<proc>" "resynthesizer3")  and marks its
texts with  _"..." ; the C engine returns "resynthesizer3" from set_i18n(). GIMP binds that domain to the
plug-in's own folder,  <plug-ins>/<name>/locale/<lang>/LC_MESSAGES/resynthesizer3.mo , and the interpreter
translates _"..." while it registers the procedure (menu label, tooltip, parameter labels, option choices).
Upstream ships no zh_TW catalog; this adds one from resynthesizer-zh_TW.po. A user whose interface language
is not Traditional Chinese keeps the English texts.

usage:
  python resynthesizer-i18n.py <resynthesizer source dir> <plug-ins dir> <review sheet .md> <plug-in name>...

  For every named plug-in (the folders under <plug-ins dir>, as installed by Resynthesizer's own build):
    1. collects the texts the plug-in really translates: _"..." in its .scm (read the way Script-Fu's reader
       reads it, so shebang/comment quirks that hide strings from xgettext do not matter) or _() / N_() in
       the engine's C sources
    2. checks resynthesizer-zh_TW.po against them: every text translated, no entry for a text that no longer
       exists (upstream renamed it), menu mnemonics and format specifiers kept, msgfmt --check clean
    3. installs the compiled catalog as <plug-ins dir>/<name>/locale/zh_TW/LC_MESSAGES/resynthesizer3.mo
  and writes a staff review section (English -> Chinese, where each text is used) to <review sheet .md>.
Needs msgfmt on PATH.
"""
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PO_FILE = os.path.join(HERE, 'resynthesizer-zh_TW.po')
DOMAIN = 'resynthesizer3'
ENGINE = 'resynthesizer'
FMT = re.compile(r'%(?:\d+\$)?[-+ #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|L|q|j|z|t)?[diouxXeEfFgGaAcspn%]')


def scheme_strings(text):
    """_"..." literals of a Script-Fu file, as TinyScheme's reader sees them: ';' starts a comment, a first
    line '#!...' is the interpreter line, #\\x is a character, "..." strings take \\n \\t \\r \\" \\\\ escapes."""
    out, i, n = [], 0, len(text)
    if text.startswith('#!'):
        i = text.find('\n')
        i = n if i < 0 else i
    while i < n:
        c = text[i]
        if c == ';':
            j = text.find('\n', i)
            i = n if j < 0 else j
        elif c == '#' and text.startswith('#\\', i):
            i += 3
            while i < n and (text[i].isalnum() or text[i] in '-_'):
                i += 1
        elif c == '"' or (c == '_' and text.startswith('_"', i)):
            marked = c == '_'
            i += 2 if marked else 1
            buf = []
            while i < n and text[i] != '"':
                if text[i] == '\\' and i + 1 < n:
                    buf.append({'n': '\n', 't': '\t', 'r': '\r'}.get(text[i + 1], text[i + 1]))
                    i += 2
                else:
                    buf.append(text[i])
                    i += 1
            i += 1
            if marked:
                out.append(''.join(buf))
        else:
            i += 1
    return out


def c_unescape(s):
    return re.sub(r'\\(.)', lambda m: {'n': '\n', 't': '\t', 'r': '\r'}.get(m.group(1), m.group(1)), s)


def c_strings(text):
    text = re.sub(r'/\*.*?\*/', ' ', text, flags=re.S)
    text = re.sub(r'(?m)//.*$', '', text)
    out = []
    for m in re.finditer(r'(?<![A-Za-z0-9_])N?_\s*\(\s*((?:"(?:[^"\\\n]|\\.)*"\s*)+)\)', text):
        out.append(''.join(c_unescape(x) for x in re.findall(r'"((?:[^"\\\n]|\\.)*)"', m.group(1))))
    return out


def po_unescape(s):
    return re.sub(r'\\(.)', lambda m: {'n': '\n', 't': '\t', 'r': '\r'}.get(m.group(1), m.group(1)), s)


def read_po(path):
    """[(msgid, msgstr, notes, fuzzy)] of a catalog whose entries are plain (no context, no plurals)."""
    entries, errors = [], []
    for n, block in enumerate(open(path, encoding='utf-8').read().replace('\r\n', '\n').split('\n\n')):
        field, vals, notes, fuzzy = None, {}, [], False
        for line in block.split('\n'):
            if line.startswith('#.'):
                notes.append(line[2:].strip())
            elif line.startswith('#,'):
                fuzzy = fuzzy or 'fuzzy' in line
            elif line.startswith('#') or not line.strip():
                continue
            else:
                m = re.match(r'^(msgctxt|msgid_plural|msgid|msgstr(?:\[\d+\])?)\s+"(.*)"\s*$', line)
                if m:
                    field = m.group(1)
                    vals[field] = m.group(2)
                elif line.startswith('"') and line.rstrip().endswith('"') and field:
                    vals[field] += line.strip()[1:-1]
                else:
                    errors.append('entry %d: cannot read line %r' % (n + 1, line))
        if 'msgid' not in vals:
            continue
        if 'msgctxt' in vals or 'msgid_plural' in vals:
            errors.append('entry %d (%s): context / plural entries are not used by these plug-ins' % (n + 1, vals['msgid']))
            continue
        entries.append((po_unescape(vals['msgid']), po_unescape(vals.get('msgstr', '')), notes, fuzzy))
    return entries, errors


def n_mnemonics(s):
    return len(re.findall(r'_(?=[^_\s])', s.replace('__', '')))


def main():
    src, plugdir, sheet, names = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
    if not names:
        sys.exit('resynthesizer i18n: no plug-in names given')
    errors = []
    used = {}                       # msgid -> [plug-in names] in source order
    for name in names:
        if name == ENGINE:
            files = sorted(os.path.join(src, 'enginePlugin', f) for f in os.listdir(os.path.join(src, 'enginePlugin'))
                           if f.endswith('.c'))
            texts = [s for f in files for s in c_strings(open(f, encoding='utf-8').read())]
        else:
            scm = os.path.join(plugdir, name, name + '.scm')
            if not os.path.isfile(scm):
                errors.append('%s: %s is missing' % (name, scm))
                continue
            text = open(scm, encoding='utf-8').read()
            # the catalog is only looked up when the script declares this domain (else it is never loaded)
            if not re.search(r'^\(script-fu-register-i18n\s+"[^"]+"\s+"%s"' % DOMAIN, text, re.M):
                errors.append('%s: the script no longer declares (script-fu-register-i18n ... "%s")' % (name, DOMAIN))
            texts = scheme_strings(text)
        for t in texts:
            if name not in used.setdefault(t, []):
                used[t].append(name)
    entries, perr = read_po(PO_FILE)
    errors += perr
    header = [e for e in entries if e[0] == '']
    if not header or 'charset=UTF-8' not in header[0][1] or 'Language: zh_TW' not in header[0][1]:
        errors.append('resynthesizer-zh_TW.po: the header must say Language: zh_TW and charset=UTF-8')
    tr = {}
    for mid, mstr, notes, fuzzy in entries:
        if mid == '':
            continue
        where = 'resynthesizer-zh_TW.po (%s)' % mid
        if mid in tr:
            errors.append(where + ': listed twice')
        if mid not in used:
            errors.append(where + ': no plug-in uses this text any more (upstream renamed or dropped it)')
        if not mstr.strip() or fuzzy:
            errors.append(where + ': no translation (empty or fuzzy)')
        if n_mnemonics(mstr) != min(n_mnemonics(mid), 1):
            errors.append(where + ': the translation must carry %s menu mnemonic like (_X)'
                          % ('one' if n_mnemonics(mid) else 'no'))
        if sorted(FMT.findall(mid)) != sorted(FMT.findall(mstr)):
            errors.append(where + ': format specifiers differ from the English text')
        tr[mid] = (mstr, notes)
    for t in used:
        if t not in tr:
            errors.append('resynthesizer-zh_TW.po: no translation for %r (used by %s)' % (t, ', '.join(used[t])))
    if errors:
        sys.exit('resynthesizer i18n:\n  ' + '\n  '.join(errors))

    msgfmt = shutil.which('msgfmt')
    if not msgfmt:
        sys.exit('resynthesizer i18n: msgfmt not found on PATH')
    mo = os.path.join(plugdir, '.olga-%s-zh_TW.mo' % DOMAIN)
    res = subprocess.run([msgfmt, '--check', '-o', mo, PO_FILE], capture_output=True, text=True)
    if res.returncode != 0:
        sys.exit('resynthesizer i18n: msgfmt --check failed:\n' + res.stderr)
    for name in names:
        dest = os.path.join(plugdir, name, 'locale', 'zh_TW', 'LC_MESSAGES')
        os.makedirs(dest, exist_ok=True)
        shutil.copyfile(mo, os.path.join(dest, DOMAIN + '.mo'))
    os.remove(mo)
    print('resynthesizer i18n: %d texts translated, zh_TW catalog installed for %d plug-ins (%s)'
          % (len(tr), len(names), ', '.join(names)))

    def cell(s):
        return (s or '').replace('|', '\\|').replace('\n', ' ')
    lines = ['## Resynthesizer 外掛(內容感知修復等)', '',
             '來源:`branding/gimp/resynthesizer-zh_TW.po`(gettext 翻譯檔,網域 `%s`)。要改就改那個檔,再重新建置。' % DOMAIN,
             '介面語言是繁體中文時才顯示中文;其他語言維持英文原文。',
             '「位置」是這段文字出現的地方;「用在」是哪幾個外掛(外掛資料夾名稱)。', '',
             'Source: `branding/gimp/resynthesizer-zh_TW.po` (gettext catalog, domain `%s`). %d texts.' % (DOMAIN, len(tr)), '',
             '| English | 繁中 | 位置 Where | 用在 Used by |', '|---|---|---|---|']
    for t, plugs in used.items():
        mstr, notes = tr[t]
        lines.append('| %s | %s | %s | %s |' % (cell(t), cell(mstr), cell(' '.join(notes)) or '-', ', '.join(plugs)))
    with open(sheet, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(lines) + '\n')
    print('resynthesizer i18n: review section %s' % sheet)


if __name__ == '__main__':
    main()
