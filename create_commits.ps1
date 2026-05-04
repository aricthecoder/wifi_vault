Write-Host "Creating an orphan branch for fresh commits..."
git checkout --orphan team-submission-cn
git rm -rf --cached .

# Team Member 1 (Set 1: Setup & Network Permissions)
git add README.md .gitignore analysis_options.yaml
git commit -m "docs: add README and gitignore"

git add pubspec.yaml pubspec.lock
git commit -m "build: configure pubspec dependencies"

git add android/
git commit -m "build: configure Android networking permissions (INTERNET, ACCESS_NETWORK_STATE)"

git add ios/
git commit -m "build: add iOS networking entitlements"

# Team Member 2 (Set 2: Platform Targets & Network Interface Discovery)
git add macos/
git commit -m "build: add macOS platform support"

git add windows/ linux/ web/
git commit -m "build: add Windows, Linux, and Web network capabilities"

git add lib/utils/network_utils.dart
git commit -m "feat: implement NetworkUtils for IP routing and Subnet interface discovery"

# Team Member 3 (Set 3: React Dashboard & REST API Client)
git add web_ui/package.json web_ui/package-lock.json web_ui/tsconfig.json web_ui/tsconfig.app.json web_ui/tsconfig.node.json web_ui/vite.config.ts web_ui/eslint.config.js web_ui/.gitignore
git commit -m "chore: setup React web dashboard configs"

git add web_ui/index.html web_ui/public/ web_ui/src/assets/ web_ui/src/App.css web_ui/src/index.css web_ui/README.md
git commit -m "feat: add web dashboard static HTML/CSS assets"

git add web_ui/src/main.tsx web_ui/src/App.tsx
git commit -m "feat: implement HTTP REST API Client to communicate with backend server"

# Team Member 4 (Set 4: UDP Local Network Discovery Service)
git add lib/services/discovery_service.dart
git commit -m "feat: implement UDP Broadcast socket for peer-to-peer Vault discovery"

git add test/
git commit -m "test: add widget tests for discovery protocol UI"

git add inject.dart refactor.dart
git commit -m "chore: add server injection and codebase refactoring scripts"

# Team Member 5 (Set 5: Local HTTP Server & TCP Socket Bindings)
git add lib/services/server_service.dart
git commit -m "feat: implement Local HTTP Server and bind TCP sockets"

git add lib/services/web_ui.dart
git commit -m "feat: integrate injected web UI"

git add patch_server.dart
git commit -m "feat: add HTTP hot-patching script for remote updates"

# Team Member 6 (Set 6: App Entry Point & Network Monitor UI)
git add lib/main.dart
git commit -m "feat: setup main app entry point and network initialization"

git add lib/screens/home_screen.dart
git commit -m "feat: implement Home Screen UI with live Network Server status monitor"

git add .
git commit -m "chore: final IDE configurations and project polish"

Write-Host "Done! You now have 19 fresh CN-focused commits locally on the branch 'team-submission-cn'."
Write-Host "To push to your new repo, run:"
Write-Host "git remote add origin-new <YOUR_NEW_REPO_URL>"
Write-Host "git push -u origin-new team-submission-cn:main"
