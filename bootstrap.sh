#!/bin/bash
set -e

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$DOTFILES_DIR/manifest"
UNDO_DIR="$HOME/.dotfiles-undo"

# ------------------------------------------------------------------------------
# Shared helpers
# ------------------------------------------------------------------------------

get_marker() {
    local file="$1"
    echo "DOTFILES:${file#$DOTFILES_DIR/}"
}

ensure_parent() {
    local path="$1"
    local parent
    parent="$(dirname "$path")"
    if [[ ! -d "$parent" ]]; then
        echo "Creating directory $parent..."
        mkdir -p "$parent"
    fi
}

# ------------------------------------------------------------------------------
# comment strategy
# Appends a marked block to the target file.
# Creates the file if it doesn't exist.
# Deletes the file on unlink if it becomes empty.
# ------------------------------------------------------------------------------

link_comment() {
    local repo_file="$1"
    local target="$2"
    local marker
    marker="$(get_marker "$repo_file")"

    ensure_parent "$target"

    if grep -qF "# BEGIN $marker" "$target" 2>/dev/null; then
        echo "Already linked, skipping $target"
        return
    fi

    echo "Linking $target..."
    {
        echo ""
        echo "# BEGIN $marker"
        cat "$repo_file"
        echo "# END $marker"
    } >> "$target"
}

unlink_comment() {
    local repo_file="$1"
    local target="$2"
    local marker
    marker="$(get_marker "$repo_file")"

    if [[ ! -f "$target" ]]; then
        return
    fi

    if grep -qF "# BEGIN $marker" "$target"; then
        echo "Unlinking $target..."
        local escaped_marker
        escaped_marker="$(echo "$marker" | sed 's/[.\/]/\\&/g')"
        sed -i "/# BEGIN $escaped_marker/,/# END $escaped_marker/d" "$target"
    fi

    if [[ ! -s "$target" ]]; then
        echo "File is now empty, removing $target..."
        rm "$target"
    fi
}

# ------------------------------------------------------------------------------
# copy strategy
# Copies the file verbatim to the target location.
# Creates the file if it doesn't exist, skips if it does.
# Deletes the file on unlink.
# ------------------------------------------------------------------------------

link_copy() {
    local repo_file="$1"
    local target="$2"

    if [[ -f "$target" ]]; then
        echo "Already exists, skipping $target"
        return
    fi

    ensure_parent "$target"
    echo "Copying $target..."
    cp "$repo_file" "$target"
}

unlink_copy() {
    local repo_file="$1"
    local target="$2"

    if [[ ! -f "$target" ]]; then
        return
    fi

    echo "Removing $target..."
    rm "$target"
}

# ------------------------------------------------------------------------------
# ini-patch strategy
# Applies specific key=value pairs from the repo file into the target INI file,
# scoped by section. Before modifying each key, records the original value (or
# __absent__ if the key didn't exist) in ~/.dotfiles-undo/ for safe reversal.
#
# Repo file format mirrors standard INI:
#   [SectionName]
#   key=value
# ------------------------------------------------------------------------------

link_ini_patch() {
    local repo_file="$1"
    local target="$2"
    local undo_file="$UNDO_DIR/${repo_file#$DOTFILES_DIR/}"

    # If undo file already exists, patch has already been applied
    if [[ -f "$undo_file" ]]; then
        echo "Already linked, skipping $target"
        return
    fi

    ensure_parent "$target"
    ensure_parent "$undo_file"

    echo "Patching $target..."

    local current_section=""
    local last_undo_section=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip blank lines and comments
        [[ -z "$line" || "$line" =~ ^# ]] && continue

        # Section header
        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            current_section="${BASH_REMATCH[1]}"
            continue
        fi

        # key=value line
        if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"

            # Record original value in undo file before modifying.
            # Uses index() for literal string matching to avoid regex
            # interpretation of special characters in key names (|, +, etc.)
            local original
            if [[ -f "$target" ]]; then
                original="$(awk -v section="$current_section" -v key="$key" '
                    /^\[/ { in_section = ($0 == "[" section "]") }
                    in_section && index($0, key "=") == 1 { sub(/^[^=]+=/, ""); print; found=1; exit }
                    END { if (!found) print "__absent__" }
                ' "$target")"
            else
                original="__absent__"
            fi

            # Write section header to undo file only when section changes
            if [[ "$current_section" != "$last_undo_section" ]]; then
                echo "[$current_section]" >> "$undo_file"
                last_undo_section="$current_section"
            fi
            echo "$key=$original" >> "$undo_file"

            # Apply the new value to the target file
            if [[ "$original" == "__absent__" ]]; then
                # Key doesn't exist — append to the correct section, or create section
                if [[ -f "$target" ]] && grep -qF "[$current_section]" "$target"; then
                    # Insert after section header — escape special chars for sed
                    local escaped_kv
                    escaped_kv="$(echo "$key=$value" | sed 's/[\/&]/\\&/g')"
                    sed -i "/^\[$(echo "$current_section" | sed 's/[\/&]/\\&/g')\]/a $escaped_kv" "$target"
                else
                    # Section doesn't exist — append both
                    echo "" >> "$target"
                    echo "[$current_section]" >> "$target"
                    echo "$key=$value" >> "$target"
                fi
            else
                # Key exists — replace it within its section
                awk -v section="$current_section" -v key="$key" -v value="$value" '
                    /^\[/ { in_section = ($0 == "[" section "]") }
                    in_section && index($0, key "=") == 1 { print key "=" value; next }
                    { print }
                ' "$target" > "${target}.tmp" && mv "${target}.tmp" "$target"
            fi
        fi

    done < "$repo_file"
}

unlink_ini_patch() {
    local repo_file="$1"
    local target="$2"
    local undo_file="$UNDO_DIR/${repo_file#$DOTFILES_DIR/}"

    if [[ ! -f "$undo_file" ]]; then
        echo "No undo record found for $target, skipping"
        return
    fi

    echo "Restoring $target..."

    # First pass — determine which sections had ALL keys absent (we added everything in them)
    local current_section=""
    declare -A section_all_absent
    declare -A section_has_key

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            current_section="${BASH_REMATCH[1]}"
            section_all_absent["$current_section"]=true
            continue
        fi
        if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
            local original="${BASH_REMATCH[2]}"
            section_has_key["$current_section"]=true
            if [[ "$original" != "__absent__" ]]; then
                section_all_absent["$current_section"]=false
            fi
        fi
    done < "$undo_file"

    # Second pass — restore keys
    current_section=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue

        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            current_section="${BASH_REMATCH[1]}"
            continue
        fi

        if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local original="${BASH_REMATCH[2]}"

            if [[ "$original" == "__absent__" ]]; then
                # Key didn't exist before — remove it
                awk -v section="$current_section" -v key="$key" '
                    /^\[/ { in_section = ($0 == "[" section "]") }
                    in_section && index($0, key "=") == 1 { next }
                    { print }
                ' "$target" > "${target}.tmp" && mv "${target}.tmp" "$target"
            else
                # Restore original value
                awk -v section="$current_section" -v key="$key" -v value="$original" '
                    /^\[/ { in_section = ($0 == "[" section "]") }
                    in_section && index($0, key "=") == 1 { print key "=" value; next }
                    { print }
                ' "$target" > "${target}.tmp" && mv "${target}.tmp" "$target"
            fi
        fi

    done < "$undo_file"

    # Remove section headers where all keys were absent (we created the whole section)
    for section in "${!section_all_absent[@]}"; do
        if [[ "${section_all_absent[$section]}" == true ]] && [[ "${section_has_key[$section]}" == true ]]; then
            awk -v section="$section" '
                $0 == "[" section "]" { found=1; next }
                found && /^$/ { found=0; next }
                found && /^\[/ { found=0 }
                { print }
            ' "$target" > "${target}.tmp" && mv "${target}.tmp" "$target"
        fi
    done

    rm "$undo_file"

    # Clean up empty undo directories
    local undo_parent
    undo_parent="$(dirname "$undo_file")"
    rmdir --ignore-fail-on-non-empty "$undo_parent"
    rmdir --ignore-fail-on-non-empty "$UNDO_DIR" 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# Main link / unlink loops — driven by manifest
# Manifest format: <repo_path> <strategy> <target_path_relative_to_HOME>
# ------------------------------------------------------------------------------

link_packages() {
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue

        local rel_path strategy target_rel
        read -r rel_path strategy target_rel <<< "$line"

        local repo_file="$DOTFILES_DIR/$rel_path"
        local target="$HOME/$target_rel"

        if [[ ! -f "$repo_file" ]]; then
            echo "Warning: repo file not found: $repo_file"
            continue
        fi

        case "$strategy" in
            comment)   link_comment   "$repo_file" "$target" ;;
            copy)      link_copy      "$repo_file" "$target" ;;
            ini-patch) link_ini_patch "$repo_file" "$target" ;;
            *)         echo "Unknown strategy '$strategy' for $rel_path, skipping" ;;
        esac

    done < "$MANIFEST"
}

unlink_packages() {
    echo "Warning: this will remove all dotfiles managed blocks from your config files."
    echo "Your existing config outside of those blocks will be unchanged."
    read -rp "Continue? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue

        local rel_path strategy target_rel
        read -r rel_path strategy target_rel <<< "$line"

        local repo_file="$DOTFILES_DIR/$rel_path"
        local target="$HOME/$target_rel"

        case "$strategy" in
            comment)   unlink_comment   "$repo_file" "$target" ;;
            copy)      unlink_copy      "$repo_file" "$target" ;;
            ini-patch) unlink_ini_patch "$repo_file" "$target" ;;
            *)         echo "Unknown strategy '$strategy' for $rel_path, skipping" ;;
        esac

    done < "$MANIFEST"
}

# ------------------------------------------------------------------------------
# Entry point
# ------------------------------------------------------------------------------

main() {
    if [[ ! -f "$MANIFEST" ]]; then
        echo "Error: manifest file not found at $MANIFEST"
        exit 1
    fi

    if [[ "${1:-}" == "--unlink" ]]; then
        unlink_packages
        exit 0
    fi

    link_packages
}

main "$@"
