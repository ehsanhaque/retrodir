#!/bin/zsh
# Points every page at the current docs/style.css by content hash, so browsers that cached
# an older stylesheet (GitHub Pages sends max-age=600) fetch the new one. Run after editing style.css.
cd "$(dirname "$0")/../docs"
V=$(shasum style.css | cut -c1-8)
sed -i '' -E "s|href=\"style\.css(\?v=[a-f0-9]+)?\"|href=\"style.css?v=$V\"|" *.html
echo "style.css?v=$V"
