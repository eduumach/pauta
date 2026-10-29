app := "build/Pauta.app"

# Build the .app bundle (release)
build:
    swift build -c release
    rm -rf {{app}}
    mkdir -p {{app}}/Contents/MacOS {{app}}/Contents/Resources
    cp .build/release/Pauta {{app}}/Contents/MacOS/Pauta
    cp Resources/Info.plist {{app}}/Contents/Info.plist
    if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns {{app}}/Contents/Resources/; fi
    if security find-identity -p codesigning | grep -q '"Pauta Dev"'; then codesign --force --sign "Pauta Dev" {{app}}; else codesign --force --sign - {{app}}; fi

# One-time: create a stable local signing identity (stops repeated permission prompts)
setup-signing:
    ./scripts/setup-signing.sh

# Build and launch
run: build
    -pkill -x Pauta
    open {{app}}

# Copy to /Applications
install: build
    -pkill -x Pauta
    rm -rf /Applications/Pauta.app
    cp -R {{app}} /Applications/Pauta.app
    open /Applications/Pauta.app

# Regenerate the app icon
icon:
    swift scripts/make-icon.swift Resources/AppIcon.icns
