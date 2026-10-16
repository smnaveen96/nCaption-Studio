# Contributing to nCaption Studio

Thank you for helping improve nCaption Studio.

## Before You Start

- Search existing issues before opening a new one.
- For a significant feature or behavioral change, open an issue first so the approach can be discussed.
- Never include API keys, signing certificates, provisioning profiles, or private media in an issue or commit.

## Development Setup

1. Fork and clone the repository.
2. Open `nCaption Studio.xcodeproj` in Xcode 26 or later.
3. Let Xcode resolve the Swift packages.
4. Select your development team for both app targets and configure matching App Group entitlements if you want to test the Final Cut Pro extension.
5. Build the `nCaptionStudio` scheme for My Mac.

## Submitting a Change

1. Create a focused branch from the default branch.
2. Keep changes limited to one feature or fix.
3. Follow the existing Swift and SwiftUI style. Avoid force unwrapping and prefer Swift concurrency over Combine.
4. Build the project and run relevant tests before submitting.
5. Open a pull request explaining what changed, why it changed, and how it was tested. Include screenshots for visible interface changes.

By contributing, you agree that your contribution is licensed under the project's MIT License.
