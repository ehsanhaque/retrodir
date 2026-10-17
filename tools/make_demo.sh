#!/bin/zsh
# Creates a folder of placeholder files for website and manual screenshots, so no real
# personal files ever appear in them. Usage: tools/make_demo.sh [~/RetroDir-Demo]
set -e
D=${1:-$HOME/RetroDir-Demo}
REPO=$(cd "$(dirname "$0")/.." && pwd)
rm -rf "$D"
mkdir -p "$D" && cd "$D"
mkdir -p Projects/{website,game-jam,dotfiles} Photos/{2025-summer,2026-spring} Music Documents Downloads Archive Scripts

cat > notes.md <<'EOF'
# Notes

- Try the new dual-panel layout
- Press F3 to view, F4 to edit
- Cmd-T opens a terminal below the panels

## Ideas
1. Sort photos by date
2. Pack old projects into archives
3. Back up the Documents folder weekly
EOF
printf 'Buy coffee beans\nWater the plants\nCall the bike shop\nFinish the README\n' > todo.txt
printf 'month,rent,food,transport,fun\nJan,1200,410,95,120\nFeb,1200,388,90,80\nMar,1200,425,110,150\nApr,1200,398,85,95\n' > budget-2026.csv
printf 'theme = "classic"\n' > .settings
printf '#!/bin/zsh\n# Back up Documents to an external drive\nrsync -av --delete ~/Documents/ /Volumes/Backup/Documents/\n' > Scripts/backup.sh
printf 'echo "hello from RetroDir"\n' > Scripts/hello.sh
chmod +x Scripts/*.sh
printf 'Meeting notes\n=============\nShip the landing page.\nWrite release notes.\n' > Documents/meeting-notes.txt
printf 'Dear reader,\n\nThis is a sample letter used for screenshots.\n' > Documents/letter-draft.txt
printf 'Chapter 1\n\nIt was a quiet morning in the archive room.\n' > Documents/story.txt
printf '{\n  "name": "website",\n  "version": "0.3.0",\n  "private": true\n}\n' > Projects/website/package.json
printf '<!doctype html>\n<title>Hello</title>\n<h1>Hello, world</h1>\n' > Projects/website/index.html
printf 'body { font-family: system-ui; }\n' > Projects/website/style.css
printf 'export EDITOR=vim\nalias ll="ls -la"\n' > Projects/dotfiles/zshrc
printf '# Game jam\nA tiny platformer.\n' > Projects/game-jam/README.md

# Images rendered from the app icon, so Quick View has real pictures to show
ICON=$REPO/build/AppIcon.iconset
for f in vacation.jpg sunset.jpg beach.jpg; do sips -s format jpeg "$ICON/icon_512x512.png" --out Photos/2025-summer/$f >/dev/null; done
sips -s format jpeg "$ICON/icon_256x256.png" --out Photos/2026-spring/garden.jpg >/dev/null

mkfile -n 3m Music/demo-track.mp3
mkfile -n 5m Music/another-track.mp3
mkfile -n 12m Downloads/installer.dmg
(cd Documents && zip -q ../Archive/documents-2025.zip *.txt)
tar -czf Archive/photos-2024.tar.gz -C Photos 2025-summer

# Plausible, varied timestamps
touch -t 202609141030 Music Music/*
touch -t 202610021815 Documents Documents/*
touch -t 202608220940 Photos/2025-summer Photos/2025-summer/*
touch -t 202610151122 notes.md todo.txt
touch -t 202610090800 budget-2026.csv
touch -t 202607011200 Archive Archive/*

# A clean copy of the public source, for code and git screenshots
git clone -q https://github.com/ehsanhaque/retrodir.git Projects/retrodir
echo "Demo folder ready: $D"
