#!/usr/bin/env bash
# Installe les git hooks versionnés du repo dans .git/hooks/.
# Usage : ./utilities/scripts/install-hooks.sh
# Idempotent : peut être ré-exécuté pour réinstaller / mettre à jour.
#
# Les hooks vivent dans utilities/scripts/hooks/ (versionnés). Cette commande crée
# des symlinks dans .git/hooks/ pour que toute modification du hook dans
# le repo soit reflétée immédiatement, sans réinstallation.

set -euo pipefail

# Vérifie qu'on est à la racine du repo git.
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "Erreur : à exécuter depuis la racine du repo git pinkha."
    exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOKS_SRC="$REPO_ROOT/utilities/scripts/hooks"
HOOKS_DST="$REPO_ROOT/.git/hooks"

if [ ! -d "$HOOKS_SRC" ]; then
    echo "Erreur : $HOOKS_SRC introuvable."
    exit 1
fi

installed=0
for hook in "$HOOKS_SRC"/*; do
    [ -f "$hook" ] || continue
    name="$(basename "$hook")"
    dst="$HOOKS_DST/$name"

    # Supprime l'ancien hook (fichier régulier ou symlink existant).
    if [ -e "$dst" ] || [ -L "$dst" ]; then
        rm "$dst"
    fi

    # Symlink relatif depuis .git/hooks/ vers ../../utilities/scripts/hooks/<name>.
    ln -s "../../utilities/scripts/hooks/$name" "$dst"
    chmod +x "$hook"
    echo "  ✓ $name → utilities/scripts/hooks/$name"
    installed=$((installed + 1))
done

if [ $installed -eq 0 ]; then
    echo "Aucun hook trouvé dans utilities/scripts/hooks/."
    exit 0
fi

echo ""
echo "$installed hook(s) installé(s). Ils tourneront automatiquement aux"
echo "évènements git correspondants. Bypass d'urgence : git commit --no-verify."
