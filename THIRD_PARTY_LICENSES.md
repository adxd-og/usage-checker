# Third-party licenses

Omelette bundles the following third-party software.

## CodexBarCore (steipete/CodexBar)

Multi-provider usage fetching (Codex, Gemini, Antigravity) is powered by
`CodexBarCore` from <https://github.com/steipete/CodexBar>.

MIT License

Copyright (c) 2026 Peter Steinberger

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

Provider logo SVGs (`ProviderIcon-*.svg` in `SharedAssets/ProviderIcons.xcassets`) are copied from CodexBar's resources under the same MIT license. `UsageTracker/Services/KeychainNoUI.swift` adapts CodexBar's `KeychainNoUIQuery` (runtime resolution of `kSecUseAuthenticationUIFail`) under the same license.

## KeyboardShortcuts (sindresorhus/KeyboardShortcuts)

The global "peek at usage" shortcut is recorded and dispatched by
<https://github.com/sindresorhus/KeyboardShortcuts>, distributed under the MIT
License (Copyright (c) Sindre Sorhus): see
<https://github.com/sindresorhus/KeyboardShortcuts/blob/main/license>.

## Sparkle

Automatic updates are provided by Sparkle (<https://github.com/sparkle-project/Sparkle>),
distributed under its own MIT-style license: see
<https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE>.
