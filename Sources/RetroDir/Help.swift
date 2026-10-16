let helpText = """
# RetroDir - keyboard reference

On a MacBook keyboard hold fn for F-keys, or use Cmd-1 ... Cmd-0
as F1 ... F10 (Cmd-Shift-6 = Shift-F6, Cmd-Option-7 = Alt-F7, etc).
"Alt" means the Option key. Hold Shift/Option/Ctrl to see the
alternate labels on the key bar. Everything also works with the mouse.

# Function keys
F1           This help
F2           User menu (Finder, Terminal, git, checksums...)
F3           View file (text/hex) - on a folder: calculate its size
F4           Edit file in the built-in editor
F5           Copy to the other panel
F6           Rename or move to the other panel
F7           Make folder (a/b/c creates nested folders)
F8           Move to Trash
F9           Pull-down menu
F10          Quit
Shift-F3     Quick Look (also Cmd-Y)
Shift-F4     Create a new file and edit it
Shift-F5     Copy within the same panel (duplicate)
Shift-F6     Rename in place
Shift-F8     Delete permanently (no Trash)
Shift-F9     Save setup
Alt-F1/F2    Choose volume / place for the left / right panel
Alt-F4       Open with the default macOS app
Alt-F5       Pack selected files (zip, tar, tar.gz, tar.bz2, tar.xz)
Alt-F6       Unpack archive to the other panel
Alt-F7       Find files (name mask + containing text)
Alt-F8       Command history
Alt-F10      Folder hotlist (also Ctrl-D)
Alt-F12      Folder history
Ctrl-F3..F7  Sort by name / extension / time / size / unsorted
Ctrl-F9      Reverse sort order

# Panels
Tab          Switch between panels
Enter        Open folder / run script / open file in its app
Backspace    Parent folder (when the command line is empty)
Cmd-Up       Parent folder      Cmd-Down  Enter folder or bundle
Cmd-[        Back to the previous folder
Home/End     First / last entry
Left/Right   Page up / down (columns in brief mode)
Insert       Select and move down (also Space, Shift-Down)
+  -  *      Select group / unselect group / invert selection
Cmd-A        Select all
Esc          Clear command line, then show panels, then clear selection
Option-key   Quick search (type letters, Ctrl-S = next match)
Ctrl-S       Start quick search
Ctrl-1/2     Brief / full listing
Ctrl-L       Info panel in the other panel
Ctrl-Q       Quick view in the other panel (text, hex, images, archives)
Ctrl-H       Show / hide hidden files
Ctrl-F       Filter files by mask
Ctrl-R       Re-read both panels
Ctrl-U       Swap panels
Ctrl-=       Show the same folder in the other panel
Ctrl-G       Go to a folder by path
Ctrl-\\       Go to the root folder
Ctrl-T       Open Terminal.app in the current folder (external)

# Command line
Typing       Goes to the command line; Enter runs it with zsh
cd PATH      Change the panel folder (cd -, cd ~, cd ..)
Ctrl-O       Hide panels to show command output (console)
Ctrl-E/X     Previous / next command (also Option-Up/Down)
Ctrl-Enter   Insert the file name under the cursor
Ctrl-[ / ]   Insert the left / right panel path
Ctrl-C       Interrupt the running command
PgUp/PgDn    Scroll the console while panels are hidden
cls          Clear the console
Interactive programs (vim, top, ssh) need the built-in terminal (Cmd-T).

# Built-in terminal (bottom split)
Cmd-T        Open the terminal (in the active panel's folder);
             with the terminal focused: new tab
Cmd-J        Switch focus between panels and terminal
Cmd-Shift-J  Hide / show the terminal (sessions keep running)
Cmd-W        Close the current tab (closing the last one hides it)
Cmd-Shift-[ ]  Previous / next tab (also Ctrl-Tab)
Cmd-1...9    Go to tab N (while the terminal is focused)
Cmd-Shift-R  Rename the tab (or double-click it; Reset restores auto name)
Cmd-Opt-Up/Down  Make the terminal taller / shorter (or drag the tab bar)
Cmd-Shift-D  cd the terminal to the active panel's folder
Cmd-Shift-P  Move the active panel to the terminal's folder
Cmd-K        Clear the terminal screen
Cmd-C / Cmd-V  Copy selection / paste in the terminal
Ctrl-Enter   (in panels) Type the file path under the cursor into the shell
Typing in the panels while the terminal is open goes to the shell.
The shell is your login shell, started as a login shell, so ~/.zprofile,
~/.zshrc, ~/.bash_profile, Homebrew paths, ~/.ssh and ssh-agent all work.
Full xterm-256color emulation: vim, htop, ssh, tmux, mouse, true color.

# Clipboard and Finder
Cmd-C        Copy full path(s) of the selection (also as files)
Cmd-Opt-C    Copy file name(s)
Cmd-V        Paste files copied in Finder into this panel
Cmd-R        Reveal in Finder      Cmd-I  Get info
Drag & drop  Drop files from Finder onto the window to copy/move them
Cmd-+ / Cmd--  Larger / smaller font

# Viewer (F3)
F2 wrap  F4 hex/text  F5 go to line/offset/percent  F7 search
Shift-F7 or n  next match  Arrows/PgUp/PgDn/Home/End scroll  Esc quit

# Editor (F4)
F2 / Cmd-S save   Shift-F2 save as   F7 / Cmd-F search   Shift-F7 next
F6 replace   F8 / Ctrl-Y delete line   F3 start/stop marking
Shift-arrows select   Cmd-C/X/V clipboard   Cmd-Z undo  Cmd-Shift-Z redo
Cmd-A select all   Cmd-D duplicate line   Tab/Shift-Tab indent
Esc / F10 close (asks to save changes)

# Copy / move conflicts
When a file exists you can Overwrite, overwrite All, Skip, Skip all,
take the Newer file, or Cancel. Copies use APFS clones when possible
and keep permissions, dates, extended attributes and ACLs.

# Mouse
Click selects, double-click opens, right-click toggles selection,
the wheel scrolls, the menu bar and key bar are clickable.

# About
RetroDir is an experimental, non-commercial project built with AI
(Claude Code). Original code and artwork; not affiliated with or
endorsed by any other file manager or its owners. Provided as is,
without warranty. It can move and delete files, so keep backups.
Copyright (c) 2026 Ehsan Haque, MIT licence. Terminal emulation by
SwiftTerm (MIT licence). Options > Licences shows the full texts.
"""
