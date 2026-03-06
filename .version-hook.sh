#!/bin/bash
if [ -z "$1" ]; then
  echo "Error: Version number required"
  exit 1
fi
NEW_VERSION="$1"
sed -i.bak "s/^VERSION=\".*\"/VERSION=\"$NEW_VERSION\"/" subtool && rm subtool.bak
echo "Updated subtool to version $NEW_VERSION"
