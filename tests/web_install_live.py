#!/usr/bin/env python3
"""Drive the box's Host Management page in a real browser engine (WebKit, the
engine behind Safari, whose upload quirks shaped the page script), against
the LIVE box:

    tests/web_install_live.py <box> <bundle.tar> [--install] [--reboot] [--shots DIR]

Uploads the bundle through the page's own file input and chunked uploader,
then (--install) presses Install and follows the progress bar to "will be
executed on reboot", then (--reboot) presses Reboot and waits for the box to
come back on the new slot, checked against /status.json.

This changes the box: --install writes its other slot, --reboot reboots it.
Kodi must not be playing (the installer refuses).
"""
import argparse
import json
import os
import sys
import tarfile
import time
import urllib.request

from playwright.sync_api import sync_playwright


def status(base):
    with urllib.request.urlopen(base + '/status.json', timeout=10) as r:
        return json.load(r)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('box', help='address or name, e.g. symphony-coreelec-0.local')
    ap.add_argument('bundle')
    ap.add_argument('--install', action='store_true')
    ap.add_argument('--reboot', action='store_true')
    ap.add_argument('--shots', default='/tmp/web_install_live')
    a = ap.parse_args()
    base = 'http://%s' % a.box
    os.makedirs(a.shots, exist_ok=True)
    with tarfile.open(a.bundle) as tf:
        man = dict(l.split('=', 1) for l in tf.extractfile('MANIFEST').read().decode().splitlines() if '=' in l)
    version = man['VERSION']
    before = status(base)
    print('box: running %s, selected %s; bundle %s' % (before['running'], before['selected'], version))

    with sync_playwright() as p:
        b = p.webkit.launch()
        page = b.new_page(viewport={'width': 1100, 'height': 900})
        page.on('dialog', lambda d: d.accept())
        page.goto(base + '/host_management')
        page.screenshot(path=os.path.join(a.shots, '1-before.png'), full_page=True)

        t0 = time.time()
        page.set_input_files('#firmwareFile', a.bundle)
        # Wait for the uploader's own end, then the reload it triggers: an
        # earlier upload left on the box already shows "ready", and pressing
        # Install on that while this one is still going aborts it (measured).
        with page.expect_navigation(timeout=30 * 60 * 1000):
            page.click('#firmwareSubmit')
            page.wait_for_function(
                "['Upload complete!', 'Already uploaded'].includes("
                "document.getElementById('uploadStatus').textContent) ||"
                " document.getElementById('uploadStatus').textContent === 'Upload failed'",
                timeout=30 * 60 * 1000)
            if page.text_content('#uploadStatus') == 'Upload failed':
                print('upload FAILED: ' + page.text_content('#uploadStats'))
                return 1
        page.wait_for_function(
            "document.body.innerText.includes('Firmware file ready for installation: ' + %s)"
            % json.dumps(os.path.basename(a.bundle)), timeout=60000)
        mb = os.path.getsize(a.bundle) / 1048576.0
        dt = time.time() - t0
        print('upload: %.0f MB in %.0fs (%.1f MB/s)' % (mb, dt, mb / dt))
        page.screenshot(path=os.path.join(a.shots, '2-uploaded.png'), full_page=True)
        if not a.install:
            b.close()
            return 0

        t0 = time.time()
        page.click('input[value^="Install Firmware"]')
        page.wait_for_selector('#uploadProgress', state='visible', timeout=60000)
        time.sleep(3)
        page.screenshot(path=os.path.join(a.shots, '3-installing.png'), full_page=True)
        page.wait_for_function(
            "document.body.innerText.includes('will be executed on reboot') ||"
            " document.body.innerText.includes('FAILED')", timeout=20 * 60 * 1000)
        page.screenshot(path=os.path.join(a.shots, '4-installed.png'), full_page=True)
        if 'FAILED' in page.inner_text('body'):
            print('install FAILED:\n' + page.inner_text('#uploadStats'))
            b.close()
            return 1
        print('install: %.0fs' % (time.time() - t0))
        st = status(base)
        tgt = st['selected']
        ok = tgt != before['running'] and st['slots'][tgt]['version'] == version
        print('selected %s = %s: %s' % (tgt, st['slots'][tgt]['version'], 'OK' if ok else 'WRONG'))
        if not ok:
            b.close()
            return 1
        if not a.reboot:
            b.close()
            return 0

        page.click('input[value^="Reboot System"]')
        b.close()

    t0 = time.time()
    time.sleep(15)
    while time.time() - t0 < 300:
        try:
            st = status(base)
            break
        except OSError:
            time.sleep(5)
    else:
        print('box did not come back within 5 minutes')
        return 1
    ok = st['running'] == tgt and st['slots'][tgt]['version'] == version
    print('after reboot (%.0fs): running %s = %s: %s'
          % (time.time() - t0, st['running'], st['slots'][st['running']]['version'], 'OK' if ok else 'WRONG'))
    with sync_playwright() as p:
        b = p.webkit.launch()
        page = b.new_page(viewport={'width': 1100, 'height': 900})
        page.goto(base + '/host_management')
        page.screenshot(path=os.path.join(a.shots, '5-after-reboot.png'), full_page=True)
        b.close()
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
