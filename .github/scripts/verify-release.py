#!/usr/bin/env python3
"""Local release checks. Never creates/replaces Apple signing assets."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import subprocess
import tempfile
import zipfile

POLICY = json.loads(Path(__file__).with_name('release-policy.json').read_text())


def check(ok, message):
    if not ok:
        raise ValueError(message)


def run(*args):
    result = subprocess.run(args, capture_output=True)
    check(result.returncode == 0, 'Local release verification command failed; command output withheld.')
    return result.stdout


def decode(path):
    return plistlib.loads(run('security', 'cms', '-D', '-i', str(path)))


def verify_profile(profile, target, certificate=None, now=None, policy=POLICY):
    now = now or dt.datetime.now(dt.timezone.utc)
    e = profile.get('Entitlements', {})
    expiry, created = profile.get('ExpirationDate'), profile.get('CreationDate')
    check(isinstance(expiry, dt.datetime) and expiry.replace(tzinfo=dt.timezone.utc) > now + dt.timedelta(hours=1)
          and isinstance(created, dt.datetime) and created.replace(tzinfo=dt.timezone.utc) <= now, 'Profile validity is insufficient.')
    check(str(profile.get('UUID', '')).lower() == target['uuid'] and profile.get('Name') == target['name']
          and profile.get('TeamIdentifier') == [policy['teamId']]
          and profile.get('ApplicationIdentifierPrefix') == [policy['teamId']]
          and 'iOS' in profile.get('Platform', []) and 'ProvisionedDevices' not in profile
          and profile.get('ProvisionsAllDevices') is not True, 'Profile identity, platform or distribution type differs.')
    check(e.get('application-identifier') == policy['teamId'] + '.' + target['bundleId']
          and e.get('com.apple.developer.team-identifier') == policy['teamId']
          and e.get('get-task-allow') is False and e.get('beta-reports-active') is True, 'Profile app/team or distribution entitlement differs.')
    check(e.get('com.apple.security.application-groups', []) == target['groups'], 'Profile App Groups differ.')
    check(e.get('com.apple.developer.applesignin', []) == target['appleSignin'], 'Profile Apple sign-in entitlement differs.')
    check(e.get('aps-environment') == target['push'], 'Profile push entitlement differs.')
    if target.get('associatedDomains'):
        domains = e.get('com.apple.developer.associated-domains', [])
        check(domains == ['*'] or all(d in domains for d in target['associatedDomains']), 'Profile Associated Domains are insufficient.')
    certificates = profile.get('DeveloperCertificates', [])
    check(len(certificates) == 1 and hashlib.sha256(certificates[0]).hexdigest() == policy['certificateSha256'], 'Profile certificate differs.')
    if certificate is not None:
        check(hashlib.sha256(certificate).hexdigest() == policy['certificateSha256'], 'Imported certificate differs.')


def install_profiles(directory, certificate, destination, policy=POLICY):
    # Validate every profile first. Never overwrite a cached profile at the same UUID.
    values = []
    for name, target in policy['profiles'].items():
        path = directory / (name + '.mobileprovision')
        content = path.read_bytes()
        verify_profile(decode(path), target, certificate, policy=policy)
        dest = destination / (target['uuid'] + '.mobileprovision')
        if dest.exists():
            check(dest.read_bytes() == content, 'Existing cached profile differs; preserve it and stop.')
        values.append((dest, content))
    destination.mkdir(parents=True, exist_ok=True)
    for path, content in values:
        if not path.exists():
            with path.open('xb') as output:
                output.write(content)
            path.chmod(0o600)


def identity(sha, build):
    check(re.fullmatch('[0-9a-f]{40}', sha) and re.fullmatch('[1-9][0-9]*', build), 'Full source SHA and positive build required.')
    check(run('git', 'rev-parse', 'HEAD').decode().strip() == sha, 'Checkout SHA differs.')
    check(run('git', 'rev-list', '--count', 'HEAD').decode().strip() == build, 'Build must equal complete Git commit count.')


def source(sha, build, prepare=False, policy=POLICY):
    identity(sha, build)
    if prepare:
        check(not run('git', 'status', '--porcelain').strip(), 'Release checkout must start clean.')
        for path in policy['infoPlists']:
            value = plistlib.loads(Path(path).read_bytes())
            value['ReleaseCommit'] = sha
            Path(path).write_bytes(plistlib.dumps(value, sort_keys=False))
    else:
        changed = run('git', 'diff', '--name-only', 'HEAD').decode().splitlines()
        check(set(changed) <= set(policy['infoPlists']), 'Unexpected tracked source changes.')
        check(not run('git', 'ls-files', '--others', '--exclude-standard').strip(), 'Unexpected untracked release source.')
        for path in policy['infoPlists']:
            original = plistlib.loads(run('git', 'show', 'HEAD:' + path))
            current = plistlib.loads(Path(path).read_bytes())
            check(current.get('ReleaseCommit') == sha, 'Missing full source stamp.')
            for key in set(original) | set(current):
                if key not in policy['configuredPlistKeys'] + ['ReleaseCommit']:
                    check(original.get(key) == current.get(key), 'Unexpected source plist change.')


def export_options(policy=POLICY):
    return dict(method='app-store-connect', destination='export', teamID=policy['teamId'], signingStyle='manual',
                signingCertificate=policy['certificateSha1'], manageAppVersionAndBuildNumber=False,
                testFlightInternalTestingOnly=True, stripSwiftSymbols=True, uploadSymbols=True,
                provisioningProfiles={p['bundleId']: p['uuid'] for p in policy['profiles'].values()})


def inspect_package(ipa, sha, build, policy=POLICY):
    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        check(len(names) == len(set(names)) and all(not PurePosixPath(n).is_absolute() and '..' not in PurePosixPath(n).parts for n in names), 'Unsafe or duplicate IPA paths.')
        apps = [n for n in names if re.fullmatch(r'Payload/[^/]+\.app/Info\.plist', n)]
        check(len(apps) == 1, 'Expected one iOS application.')
        main = apps[0]
        extension_prefix = main.removesuffix('Info.plist') + 'PlugIns/'
        infos = [main] + [n for n in names if n.startswith(extension_prefix) and re.fullmatch(r'[^/]+\.appex/Info\.plist', n[len(extension_prefix):])]
        check(len(infos) == len(policy['profiles']), 'Unexpected or missing app extensions.')
        all_bundles = [n for n in names if n.endswith(('.app/Info.plist', '.appex/Info.plist'))]
        check(set(all_bundles) == set(infos), 'Unexpected nested application or extension.')
        bundles, paths = set(), []
        for path in infos:
            info = plistlib.loads(archive.read(path)); bundle = info.get('CFBundleIdentifier')
            check(bundle not in bundles and bundle in [p['bundleId'] for p in policy['profiles'].values()], 'Unexpected artifact bundle.')
            bundles.add(bundle)
            check(info.get('CFBundleShortVersionString') == policy['marketingVersion'] and info.get('CFBundleVersion') == build
                  and info.get('ReleaseCommit') == sha and info.get('DTPlatformName') == 'iphoneos', 'Artifact version/build/source/platform differs.')
            if path == main and policy.get('apiOrigin'):
                check(info.get('API_BASE_URL') == policy['apiOrigin'], 'Artifact production origin differs.')
            profile_path = path.removesuffix('Info.plist') + 'embedded.mobileprovision'
            check(profile_path in names, 'Artifact has no embedded existing profile.')
            paths.append((path.removesuffix('/Info.plist'), bundle))
        return paths


def artifact(ipa, sha, build, policy=POLICY):
    paths = inspect_package(ipa, sha, build, policy)
    with tempfile.TemporaryDirectory(prefix='verify-native-') as directory:
        run('ditto', '-x', '-k', str(ipa), directory)
        for relative, bundle in paths:
            app = Path(directory) / relative
            target = next(p for p in policy['profiles'].values() if p['bundleId'] == bundle)
            verify_profile(decode(app / 'embedded.mobileprovision'), target, policy=policy)
            run('codesign', '--verify', '--deep', '--strict', str(app))
            prefix = str(Path(directory) / 'signing-cert-')
            run('codesign', '-d', '--extract-certificates', prefix, str(app))
            check(hashlib.sha256(Path(prefix + '0').read_bytes()).hexdigest() == policy['certificateSha256'], 'Artifact signing identity differs.')
            e = plistlib.loads(run('codesign', '-d', '--entitlements', ':-', str(app)))
            check(e.get('application-identifier') == policy['teamId'] + '.' + bundle
                  and e.get('com.apple.developer.team-identifier') == policy['teamId']
                  and e.get('get-task-allow', False) is False
                  and e.get('com.apple.security.application-groups', []) == target['groups'], 'Signed artifact identity or App Groups differ.')
            if target['appleSignin'] and target is policy['profiles']['app']:
                check(e.get('com.apple.developer.applesignin') == ['Default'], 'Signed app lacks Apple sign-in.')
            if target['push']:
                check(e.get('aps-environment') == target['push'], 'Signed app lacks production push.')
            if target.get('associatedDomains'):
                check(e.get('com.apple.developer.associated-domains') == target['associatedDomains'], 'Signed app Associated Domains differ.')
    return {'sha': sha, 'build': build, 'appId': policy['appId'], 'ipaSha256': hashlib.sha256(Path(ipa).read_bytes()).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['prepare-source', 'source', 'profiles', 'export-options', 'artifact'])
    for name in ['sha', 'build', 'directory', 'certificate-der', 'destination', 'output', 'ipa']:
        parser.add_argument('--' + name)
    args = parser.parse_args()
    if args.mode in ['prepare-source', 'source']:
        source(args.sha, args.build, args.mode == 'prepare-source')
    elif args.mode == 'profiles':
        install_profiles(Path(args.directory), Path(args.certificate_der).read_bytes(), Path(args.destination))
    elif args.mode == 'export-options':
        with open(args.output, 'xb') as file:
            plistlib.dump(export_options(), file)
    else:
        source(args.sha, args.build)
        print(json.dumps(artifact(args.ipa, args.sha, args.build)))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        raise SystemExit(str(error))
