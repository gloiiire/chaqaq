# Captures de référence — Books.app

Dossier de travail pour reproduire la feature de thèmes de Books.

Les couleurs, libellés, identifiants et valeurs typographiques ont été
extraits directement du binaire — voir `../BOOKS-READER-SETTINGS-RE.md`,
section 10. **La géométrie, non** : les deux sheets sont en SwiftUI, donc
paddings, marges, tailles et rayons sont compilés dans du code de layout.
Ni nib, ni plist à lire. Ils doivent être mesurés sur des captures.

## Ce qu'il faut déposer ici

Depuis un iPhone sous iOS 27, dans Books, un livre ouvert :

| Fichier | Écran |
| --- | --- |
| `01-themes-clair.png` | « Thèmes et réglages », apparence claire |
| `02-themes-sombre.png` | le même, apparence sombre |
| `03-personnaliser-clair.png` | « Personnaliser le thème », clair |
| `04-personnaliser-sombre.png` | le même, sombre |

Utiles en complément, si l'occasion se présente :

| Fichier | Écran |
| --- | --- |
| `05-themes-scrolle.png` | la grille de thèmes défilée, pour voir les thèmes hors écran |
| `06-personnaliser-police.png` | le sélecteur de police ouvert |
| `07-themes-dynamic-type.png` | avec une taille de texte système augmentée |

## Consignes de prise de vue

- **Capture système** (volume haut + latéral), pas une photo d'écran.
- **Ne pas rogner, ne pas redimensionner.** Les dimensions natives portent
  l'information : sur un écran 3×, 1 point = 3 pixels, et c'est ce rapport qui
  permet de convertir les mesures en valeurs SwiftUI.
- Éviter le mode sombre automatique en cours de capture (bascule au coucher du
  soleil) : forcer l'apparence dans Réglages le temps des deux prises.

## Pourquoi elles ne sont pas versionnées

Le `.gitignore` de ce dossier exclut toutes les images. Le dépôt est public et
ces captures montrent l'interface d'Apple : elles servent de référence de
mesure pendant le développement, pas de contenu à redistribuer. Seul ce README
est suivi par git.
