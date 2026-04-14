#!/bin/bash

set -e

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"

get_marker() {
    local file="$1"
    echo "DOTFILES:${file#$DOTFILES_DIR/}"
}

link_packages() {
    cd "$DOTFILES_DIR"
    for dir in */; do
        local package="${dir%/}"
        while IFS= read -r -d '' file; do
            local relative="${file#$DOTFILES_DIR/$package}"
            local target="$HOME$relative"
            local marker
            marker="$(get_marker "$file")"
            local parent
            parent="$(dirname "$target")"

            if [[ ! -d "$parent" ]]; then
                echo "Creating directory $parent..."
                mkdir -p "$parent"
            fi

            if grep -qF "# BEGIN $marker" "$target" 2>/dev/null; then
                echo "Already linked, skipping $target"
                continue
            fi

            echo "Linking $target..."
            {
                echo ""
                echo "# BEGIN $marker"
                cat "$file"
                echo "# END $marker"
            } >> "$target"

        done < <(find "$DOTFILES_DIR/$package" -type f -print0)
    done
}

unlink_packages() {
    echo "Warning: this will remove all dotfiles managed blocks from your config files."
    echo "Your existing config outside of those blocks will be unchanged."
    read -rp "Continue? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 0

    cd "$DOTFILES_DIR"
    for dir in */; do
        local package="${dir%/}"
        while IFS= read -r -d '' file; do
            local relative="${file#$DOTFILES_DIR/$package}"
            local target="$HOME$relative"
            local marker
            marker="$(get_marker "$file")"

            if [[ ! -f "$target" ]]; then
                continue
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

        done < <(find "$DOTFILES_DIR/$package" -type f -print0)
    done
}

main() {
    if [[ "$1" == "--unlink" ]]; then
        unlink_packages
        exit 0
    fi

    link_packages
}

main "$@"
