# Mac Deployment Setup

## 1. Move the repo to the Mac

Use Git, `scp`, or a shared folder to put the `CodexWatch` workspace on the MacBook Air.

## 2. Bootstrap the Mac

From Terminal on the Mac:

```bash
cd /path/to/CodexWatch
chmod +x scripts/mac/*.sh
./scripts/mac/bootstrap-mac.sh
```

## 3. Fill in signing and runtime values

Copy:

```bash
cp macos/CodexWatch/Config/Local.example.xcconfig macos/CodexWatch/Config/Local.xcconfig
```

Then edit `Local.xcconfig` with:

- `DEVELOPMENT_TEAM`
- `PRODUCT_BUNDLE_IDENTIFIER`
- `CODEX_WATCH_RELAY_BASE_URL`
- `CODEX_WATCH_RELAY_TOKEN`

Use the Windows LAN IP for `CODEX_WATCH_RELAY_BASE_URL`, not `127.0.0.1`.

## 4. Generate the project

```bash
./scripts/mac/generate-project.sh
```

## 5. Build and inspect destinations

```bash
./scripts/mac/build-watch.sh
./scripts/mac/show-destinations.sh
```

If signing or device trust is incomplete, finish those in Xcode and on the iPhone / Watch, then build again.

## 6. First device deploy

For the first real install, open the generated project in Xcode:

```bash
./scripts/mac/open-xcode.sh
```

Then:

- sign in to Xcode with your Apple ID
- select your team
- connect and trust the iPhone once
- keep the Apple Watch unlocked and on-wrist or nearby
- approve Developer Mode or trust prompts as they appear

After the first successful run, Codex on the Mac can stay mostly CLI-driven for rebuilds.
