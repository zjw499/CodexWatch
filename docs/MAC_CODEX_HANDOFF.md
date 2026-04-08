# Mac Codex Handoff

Give the MacBook Air Codex this prompt:

```text
You are working in the CodexWatch repository.

Goal:
- turn the existing watchOS source into a signed, locally deployable Apple Watch app on this Mac
- keep the Windows machine as the relay/backend host

Repository expectations:
- the watch source already exists under watchos/CodexWatch
- the XcodeGen spec is at project.yml
- Mac helper scripts are in scripts/mac
- signing/runtime config templates are in macos/CodexWatch/Config

Do this in order:
1. Verify Xcode is installed and usable with xcodebuild.
2. Run scripts/mac/bootstrap-mac.sh.
3. Copy macos/CodexWatch/Config/Local.example.xcconfig to Local.xcconfig if needed, then stop and tell me exactly which values I must fill in:
   - DEVELOPMENT_TEAM
   - PRODUCT_BUNDLE_IDENTIFIER
   - CODEX_WATCH_RELAY_BASE_URL
   - CODEX_WATCH_RELAY_TOKEN
4. After I fill those values in and sign into Xcode, run scripts/mac/generate-project.sh.
5. Open the generated Xcode project and verify the CodexWatch target includes the watchos/CodexWatch sources and resource assets.
6. Build the scheme from CLI with scripts/mac/build-watch.sh.
7. Show connected destinations with scripts/mac/show-destinations.sh.
8. If the paired iPhone and Apple Watch are visible, tell me any trust / Developer Mode / signing actions I must complete locally.
9. Once those are done, build again for the real watch destination and report any remaining errors precisely.

Important constraints:
- do not change the product scope; only make the project buildable and deployable on this Mac
- do not add APNs or cloud deployment work
- prefer CLI and deterministic project changes over manual Xcode clicking
- if you need to edit files, explain why and keep the changes minimal
```

## Windows Side

Run the relay on Windows with:

```powershell
D:\CodexWatch\scripts\windows\start-relay-lan.ps1 -Workspace "D:\Projects;D:\Repos" -DesktopId "home-ultra-pc" -DesktopName "Home PC"
```

Print the LAN URL with:

```powershell
D:\CodexWatch\scripts\windows\show-relay-url.ps1
```
