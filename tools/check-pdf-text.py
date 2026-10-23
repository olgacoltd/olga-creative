#!/usr/bin/env python3
"""Check that a PDF exported by the smoke test contains live (selectable) text.

usage: python -I tools/check-pdf-text.py <cjk.pdf> [expected text ...]
Default expectation: the Traditional Chinese test string written by smoke-test-inkscape.ps1.
Exit 0 when every expected string is found in the PDF text layer. Needs pypdfium2.
"""
import sys

import pypdfium2 as pdfium

path = sys.argv[1]
expected = sys.argv[2:] or ['向量設計測試', 'smoke test 123']
pdf = pdfium.PdfDocument(path)
text = ''.join(pdf[i].get_textpage().get_text_range() for i in range(len(pdf)))
print('pages: %d, text chars: %d' % (len(pdf), len(text)))
print('text: %r' % text[:200])
missing = [e for e in expected if e not in text]
for e in expected:
    print('%-8s %r' % ('FOUND' if e not in missing else 'MISSING', e))
sys.exit(1 if missing else 0)
