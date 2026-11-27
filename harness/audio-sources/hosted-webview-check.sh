#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/tweak/Sources"
OUT="$ROOT/harness/audio-sources/build/hosted-webview"
APP="$OUT/HostedWebView.app"
rm -rf "$APP"
mkdir -p "$APP"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator clang -target "$(uname -m)-apple-ios17.0-simulator" -isysroot "$SDK" \
  -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-parameter \
  -I"$SRC" "$ROOT/harness/audio-sources/hosted-webview.m" "$ROOT/harness/scene.m" \
  "$SRC/Shared/AudioSources/SGHostedLosslessPage.m" "$SRC/Shared/AudioSources/SGHostedAuthPolicy.m" \
  -framework Foundation -framework UIKit -framework WebKit -framework Security -framework CoreGraphics -o "$APP/HostedWebView"
python3 - "$APP" <<'PY'
from pathlib import Path
import plistlib,sys
info={'CFBundleExecutable':'HostedWebView','CFBundleIdentifier':'dev.vitrine.hosted-webview','CFBundleName':'HostedWebView',
 'CFBundleVersion':'1','CFBundleShortVersionString':'1.0','UILaunchScreen':{},
 'UIApplicationSceneManifest':{'UISceneConfigurations':{'UIWindowSceneSessionRoleApplication':[
 {'UISceneConfigurationName':'Default','UISceneDelegateClassName':'SGRHarnessScene'}]}}}
(Path(sys.argv[1])/'Info.plist').write_bytes(plistlib.dumps(info))
PY
xattr -cr "$APP"
codesign --force --sign - "$APP"
python3 - "$APP" "$OUT" <<'PY'
from pathlib import Path
import json,subprocess,sys,uuid
app,out=Path(sys.argv[1]),Path(sys.argv[2])
def run(args,timeout=30,**kwargs):
    return subprocess.run(args,capture_output=True,text=True,timeout=timeout,**kwargs)
listed=run(['xcrun','simctl','list','devices','available','-j'])
if listed.returncode or not listed.stdout.strip():
    raise SystemExit('FAIL: CoreSimulator service is unavailable; app compiled and signed, but WKWebView execution could not start')
devices=json.loads(listed.stdout)['devices']
matches=[d for runtime,ds in devices.items() if '.iOS-' in runtime for d in ds if d.get('isAvailable') and 'iPhone' in d['name']]
if not matches: raise SystemExit('FAIL: no available iPhone Simulator')
device=matches[0]['udid']
run(['xcrun','simctl','boot',device],timeout=30)
run(['xcrun','simctl','bootstatus',device,'-b'],timeout=120)
run(['xcrun','simctl','install',device,str(app)],timeout=45)
container=run(['xcrun','simctl','get_app_container',device,'dev.vitrine.hosted-webview','data'],timeout=30,check=True).stdout.strip()
receipt=Path(container)/'Documents/hosted-webview-result.json'
run_id=uuid.uuid4().hex
try:
    result=run(['xcrun','simctl','launch','--console',device,'dev.vitrine.hosted-webview'],timeout=30,
      env={**__import__('os').environ,'SIMCTL_CHILD_SG_HOSTED_WEBVIEW_RUN_ID':run_id})
except subprocess.TimeoutExpired as e:
    raise SystemExit('FAIL: simulator app exceeded bounded 30 second launch window') from e
print(result.stdout+result.stderr,end='')
if result.returncode: raise SystemExit(f'FAIL: simulator process exited {result.returncode}')
try: data=json.loads(receipt.read_text())
except Exception as e: raise SystemExit(f'FAIL: missing simulator receipt: {e}') from e
if data.get('run')!=run_id or data.get('passed') is not True or data.get('calls')!=1 or data.get('grant')!='gr_fixture':
    raise SystemExit(f'FAIL: simulator receipt does not confirm bridge exchange: {data}')
print('PASS: real WKWebView loaded allowed child frames and delivered one grant via production bridge')
run(['xcrun','simctl','terminate',device,'dev.vitrine.hosted-webview'],timeout=15)
PY
