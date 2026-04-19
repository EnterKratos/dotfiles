# dotfiles

Personal configuration files managed by `bootstrap.sh`.

## Repo structure

```
dotfiles/
  bootstrap.sh
  manifest
  bash/
    .bashrc
  kde/
    kglobalshortcutsrc
  autostart/
    com.github.hluk.copyq.desktop
```

The top-level folders are logical groupings only — they have no effect on where files are installed.

## Usage

Apply all dotfiles:

```
./bootstrap.sh
```

Remove all dotfiles:

```
./bootstrap.sh --unlink
```

## Manifest

The `manifest` file drives everything. Each line has three columns:

```
<repo path>    <strategy>    <target path relative to $HOME>
```

Example:

```
bash/.bashrc    comment    .bashrc
```

Lines starting with `#` are treated as comments.

## Strategies

### comment

Appends a marked block to the target file. The existing file content is left untouched — only the managed block is added or removed. If the target file doesn't exist it is created. If the file is empty after unlinking it is deleted.

Use this for config files that already exist on the system and support `#` comments, such as `.bashrc` and `.desktop` files.

### copy

Copies the repo file verbatim to the target location. Skips if the target already exists. Deletes the target on unlink.

Use this for files that are entirely owned by dotfiles and have no pre-existing content to preserve.

### ini-patch

Applies specific key/value pairs from the repo file into the target INI file, scoped by section. Only the specified keys are modified — everything else in the file is left untouched.

Before modifying each key, the original value is recorded in `~/.dotfiles-undo/` mirroring the repo structure. On unlink, each key is restored to its original value. If all keys in a section were absent before patching, the section header is also removed on unlink.

Use this for INI-format config files that do not support comments and are shared with other software, such as KDE config files.

## Adding a new file

1. Create the repo file under an appropriate package folder
2. Add a line to `manifest` with the repo path, strategy, and target path
3. Run `./bootstrap.sh`

## Undo store

The `ini-patch` strategy stores original key values at `~/.dotfiles-undo/`, mirroring the repo structure. This directory is managed automatically — do not edit it manually.
