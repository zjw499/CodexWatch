"""Check the final phone/Watch bundles contain the reviewed privacy declarations."""
import argparse
from pathlib import Path
import plistlib


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    expected_path = Path(__file__).resolve().parents[1] / 'privacy' / 'PrivacyInfo.xcprivacy'
    with expected_path.open('rb') as source:
        expected = plistlib.load(source)
    bundles = [args.app] + list(args.app.rglob('*.app')) + list(args.app.rglob('*.appex'))
    checked = 0
    for bundle in bundles:
        with (bundle / 'Info.plist').open('rb') as source:
            info = plistlib.load(source)
        if not info.get('CFBundleIdentifier', '').startswith('com.zachwyatt.codexwatch'):
            continue
        manifest = bundle / 'PrivacyInfo.xcprivacy'
        if not manifest.is_file():
            raise SystemExit('Missing privacy manifest in ' + bundle.name)
        with manifest.open('rb') as source:
            actual = plistlib.load(source)
        if actual != expected or actual.get('NSPrivacyTracking') is not False:
            raise SystemExit('Bundled privacy declaration differs from reviewed source: ' + bundle.name)
        checked += 1
    if checked != 3:
        raise SystemExit('Expected the phone, Watch app and Watch extension privacy manifests')
    print('Verified reviewed privacy manifests in all three native bundles')


if __name__ == '__main__':
    main()
