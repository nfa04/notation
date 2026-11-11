#!/usr/bin/env python3
"""Writes the AltStore "source" file of a release: the list that AltStore reads to show Notation and to offer its updates.

  python3 tool/make_altstore_source.py --ipa Notation-ios-unsigned.ipa --repo nfa04/notation --tag v0.0.2 --out altstore.json

The release workflow runs it and attaches the file to the release, so that
https://github.com/<repo>/releases/latest/download/altstore.json always names the newest version (add that address in AltStore).
"""
import argparse, json, os, plistlib, re, datetime, zipfile

ap = argparse.ArgumentParser()
ap.add_argument('--ipa', required=True)
ap.add_argument('--repo', required=True)
ap.add_argument('--tag', required=True)
ap.add_argument('--out', required=True)
a = ap.parse_args()

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
version = re.search(r'^version:\s*([0-9.]+)', open(os.path.join(root, 'pubspec.yaml')).read(), re.M).group(1)
info = plistlib.load(open(os.path.join(root, 'ios', 'Runner', 'Info.plist'), 'rb'))
privacy = {k: v for k, v in info.items() if k.startswith('NS') and k.endswith('UsageDescription')}
target = re.search(r'IPHONEOS_DEPLOYMENT_TARGET = ([0-9.]+);', open(os.path.join(root, 'ios', 'Runner.xcodeproj', 'project.pbxproj')).read()).group(1)
build = re.search(r'^version:\s*[0-9.]+\+(\d+)', open(os.path.join(root, 'pubspec.yaml')).read(), re.M).group(1)
notes = open(os.path.join(root, 'fastlane', 'metadata', 'android', 'en-US', 'changelogs', build + '.txt')).read().strip()
base = f'https://github.com/{a.repo}/releases'

source = {
    'name': 'Notation',
    'identifier': 'io.github.nfa04.notation.source',
    'subtitle': 'Handwritten notes, PDFs and flashcards',
    'description': 'Notation, a free note-taking and PDF-annotation app.',
    'sourceURL': f'{base}/latest/download/altstore.json',
    'website': f'https://github.com/{a.repo}',
    'apps': [{
        'name': 'Notation',
        'bundleIdentifier': 'io.github.nfa04.notation',
        'developerName': 'Noel Aeby',
        'subtitle': 'Handwritten notes, PDFs and flashcards',
        'localizedDescription': open(os.path.join(root, 'fastlane', 'metadata', 'android', 'en-US', 'full_description.txt')).read().replace('<b>', '').replace('</b>', ''),
        'iconURL': f'https://raw.githubusercontent.com/{a.repo}/{a.tag}/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png',
        'tintColor': '3F51B5',
        'category': 'productivity',
        'screenshots': [],
        'versions': [{
            'version': version,
            'buildVersion': build,
            'date': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
            'localizedDescription': notes,
            'downloadURL': f'{base}/download/{a.tag}/{os.path.basename(a.ipa)}',
            'size': os.path.getsize(a.ipa),
            'minOSVersion': target,
        }],
        'appPermissions': {'entitlements': [], 'privacy': privacy},
    }],
    'news': [],
}
with open(a.out, 'w') as f:
    json.dump(source, f, indent=2)
    f.write('\n')
