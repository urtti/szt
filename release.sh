#!/bin/bash
set -euo pipefail

# Builds, packages and publishes a release of szt as a GitHub release on
# urtti/szt. Does NOT touch the Homebrew tap; run promote.sh in the
# homebrew-szt repo to point the formula at a published release.

# Check for required software
deps=(gh git swift lipo tar)
for dep in "${deps[@]}"; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    echo "ERROR: Required dependency '$dep' is not installed or not in PATH. Please install it before running this script."
    exit 1
  fi
done

# Safety check: ensure no files are staged
if [[ -n $(git diff --cached --name-only) ]]; then
  echo "ERROR: You have staged files in git. Please commit or unstage them before running this script to avoid including unintended changes in the release."
  git diff --cached --name-only
  exit 1
fi

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "Usage: $0 <semantic-version> [release-notes-file] (e.g., 1.0.1 notes.md)"
  exit 1
fi

# Tags are bare versions (1.0.1), so drop a leading v
TAG="${1#v}"
NOTES_FILE="${2:-}"

# Fail early: a missing or empty notes file should not surface after the push.
if [ -n "$NOTES_FILE" ] && [ ! -s "$NOTES_FILE" ]; then
  echo "ERROR: Release notes file '$NOTES_FILE' does not exist or is empty."
  exit 1
fi

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "ERROR: Tag $TAG already exists."
  exit 1
fi

BINARY_NAME="szt"
SWIFT_FILE="Sources/szt/Options.swift"
TARBALL=".build/szt-$TAG-macos.tar.gz"

# 1. Update the version szt reports
echo "Updating version in $SWIFT_FILE to $TAG..."
sed -i '' "s/static let version = \".*\"/static let version = \"$TAG\"/" "$SWIFT_FILE"

# 2. Build a universal binary, so the formula works on Apple silicon and Intel
echo "Building release binary..."
swift build -c release --arch arm64 --arch x86_64
BUILD_DIR=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
lipo -info "$BUILD_DIR/$BINARY_NAME"
if [ "$("$BUILD_DIR/$BINARY_NAME" --version)" != "szt $TAG" ]; then
  echo "ERROR: The built binary doesn't report version $TAG."
  exit 1
fi

# 3. Package the binary
echo "Packaging the binary into $TARBALL..."
STAGING_DIR=".build/staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp "$BUILD_DIR/$BINARY_NAME" "$STAGING_DIR/"
tar -czf "$TARBALL" -C "$STAGING_DIR" .

# 4. Commit (unless the version was already set) and tag
echo "Committing and tagging release..."
git add "$SWIFT_FILE"
if ! git diff --cached --quiet; then
  git commit -m "Release $TAG"
fi
git tag "$TAG"

# 5. Push changes and tag
echo "Pushing changes and tag to origin..."
git push
git push origin "$TAG"

# 6. Create GitHub release on urtti/szt and upload the tarball
echo "Creating GitHub release and uploading asset..."
if [ -n "$NOTES_FILE" ]; then
  NOTES_ARGS=(--notes-file "$NOTES_FILE")
else
  NOTES_ARGS=(--notes "Release $TAG")
fi
gh release create "$TAG" "$TARBALL" --title "$TAG" "${NOTES_ARGS[@]}"

rm "$TARBALL"

echo "Release $TAG published!"

cat <<EOF

Next steps:
1. Test the release binary:
   gh release download $TAG --pattern "szt-$TAG-macos.tar.gz" --dir /tmp
   tar -xzf "/tmp/szt-$TAG-macos.tar.gz" -C /tmp && /tmp/szt --version

2. When happy, publish it to Homebrew from the tap repo:
   cd ../homebrew-szt && ./promote.sh $TAG

EOF
